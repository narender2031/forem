require "rails_helper"

RSpec.describe FeedEvent do
  let(:reaction_multiplier) { FeedEvent::REACTION_SCORE_MULTIPLIER }
  let(:comment_multiplier) { FeedEvent::COMMENT_SCORE_MULTIPLIER }

  describe "validations" do
    it { is_expected.to belong_to(:article).optional }
    it { is_expected.to validate_numericality_of(:article_id).only_integer }
    it { is_expected.to belong_to(:user).optional }
    it { is_expected.to validate_numericality_of(:user_id).only_integer.allow_nil }

    it { is_expected.to define_enum_for(:category).with_values(%i[impression click reaction comment]) }
    it { is_expected.to validate_numericality_of(:article_position).is_greater_than(0).only_integer }
    it { is_expected.to validate_inclusion_of(:context_type).in_array(%w[home search tag]) }
  end

  describe ".record_journey_for" do
    subject(:record_journey) { described_class.record_journey_for(user, article: article, category: category) }

    let(:article) { create(:article) }
    let(:user) { create(:user) }
    let(:category) { :reaction }

    it "records a feed event if the user's last click was on the specified article" do
      click = create(:feed_event, user: user, article: article, category: :click)

      expect { record_journey }.to change(described_class, :count).by(1)
      expect(user.feed_events.last).to have_attributes(
        category: "reaction",
        article_id: article.id,
        user_id: user.id,
        context_type: click.context_type,
        article_position: click.article_position,
      )
    end

    it "does not record a feed event if the user has no feed events for the specified article" do
      expect { record_journey }.not_to change(described_class, :count)
      expect(user.feed_events).to be_empty
    end

    it "does not record a feed event if the user did not click through from the feed" do
      impression = create(:feed_event, user: user, article: article, category: :impression)

      expect { record_journey }.not_to change(described_class, :count)
      expect(user.feed_events).to contain_exactly(impression)
    end

    it "does not record a feed event if the user's last click was not on the specified article" do
      click = create(:feed_event, user: user, article: article, category: :click)
      other_click = create(:feed_event, user: user, category: :click)

      expect { record_journey }.not_to change(described_class, :count)
      expect(user.feed_events).to contain_exactly(click, other_click)
    end

    context "when the interaction is not a comment or reaction" do
      let(:category) { :impression }

      it "does not record a feed event" do
        click = create(:feed_event, user: user, article: article, category: :click)

        expect { record_journey }.not_to change(described_class, :count)
        expect(user.feed_events).to contain_exactly(click)
      end
    end
  end

  describe "after_save .update_article_counters_and_scores" do
    let!(:article) { create(:article) }
    let!(:user1) { create(:user) }
    let!(:user2) { create(:user) }

    it "updates article counters and scores when a FeedEvent is saved" do
      # Create some feed events to simulate behavior
      create(:feed_event, category: "impression", article: article, user: user1)
      create(:feed_event, category: "click", article: article, user: user1)
      create(:feed_event, category: "reaction", article: article, user: user1)
      create(:feed_event, category: "comment", article: article, user: user2)

      # Trigger the after_save
      create(:feed_event, category: "impression", article: article, user: user2)

      # Reload the article to get the updated counters and scores
      article.reload

      expect(article.feed_success_score).to eq((1 + reaction_multiplier + comment_multiplier) / 2.0) # Calculated score
      expect(article.feed_impressions_count).to eq(2) # Two impressions
      expect(article.feed_clicks_count).to eq(1) # One click
    end

    it "returns early if article is nil" do
      feed_event_without_article = build(:feed_event, category: "impression")
      allow(feed_event_without_article).to receive(:update_article_counters_and_scores)
      feed_event_without_article.save
      expect(feed_event_without_article).not_to have_received(:update_article_counters_and_scores)
    end

    it "initializes counters and scores to zero when no events have occurred" do
      expect do
        create(:feed_event, category: "impression", article: article, user: user1)
      end.to not_change { article.reload.feed_success_score }
        .and not_change { article.reload.feed_clicks_count }
        .and change { article.reload.feed_impressions_count }.from(0).to(1)
    end

    it "correctly updates when only one type of event occurs" do
      create(:feed_event, category: "reaction", article: article, user: user1)

      # Trigger the after_save
      create(:feed_event, category: "impression", article: article, user: user1)

      article.reload

      expect(article.feed_success_score).to eq(5.0) # One reaction by one distinct user
      expect(article.feed_impressions_count).to eq(1) # One impression
      expect(article.feed_clicks_count).to eq(0) # Zero clicks
    end

    it "considers only distinct users for each type of event for score, but not count" do
      create_list(:feed_event, 2, category: "impression", article: article, user: user1)
      create_list(:feed_event, 4, category: "click", article: article, user: user1)
      create_list(:feed_event, 3, category: "reaction", article: article, user: user2)
      create_list(:feed_event, 2, category: "comment", article: article, user: user2)

      # Trigger the after_save
      create(:feed_event, category: "impression", article: article, user: user2)

      article.reload

      expect(article.feed_success_score).to eq((1 + reaction_multiplier + comment_multiplier) / 2.0) # Calculated score
      expect(article.feed_clicks_count).to eq(4)
      expect(article.feed_impressions_count).to eq(3)
    end
  end

  describe ".bulk_update_counters_by_article_id" do
    let!(:article1) { create(:article) }
    let!(:article2) { create(:article) }
    let!(:user1) { create(:user) }
    let!(:user2) { create(:user) }

    it "updates counters and scores for multiple articles" do
      # Create some feed events for article1
      create(:feed_event, category: "impression", article: article1, user: user1)
      create(:feed_event, category: "impression", article: article1, user: user2)
      create(:feed_event, category: "impression", article: article1, user: user2) # Duplicate
      create(:feed_event, category: "click", article: article1, user: user1)
      create(:feed_event, category: "reaction", article: article1, user: user1)
      create(:feed_event, category: "comment", article: article1, user: user2)

      # Create some feed events for article2
      create(:feed_event, category: "impression", article: article2, user: user2)
      create(:feed_event, category: "click", article: article2, user: user1)
      create(:feed_event, category: "reaction", article: article2, user: user2)

      described_class.bulk_update_counters_by_article_id([article1.id, article2.id])

      article1.reload
      article2.reload

      expect(article1.feed_success_score).to eq((1 + reaction_multiplier + comment_multiplier) / 2.0) # Calculated score
      expect(article1.feed_impressions_count).to eq(3)
      expect(article1.feed_clicks_count).to eq(1)

      expect(article2.feed_success_score).to eq((1 + 5) / 1.0) # Calculated score
      expect(article2.feed_impressions_count).to eq(1)
      expect(article2.feed_clicks_count).to eq(1)
    end

    it "skips articles with no impressions" do
      # Create some feed events for article2, but none for article1
      create(:feed_event, category: "click", article: article2, user: user1)
      create(:feed_event, category: "reaction", article: article2, user: user2)
      create(:feed_event, category: "comment", article: article2, user: user2)

      described_class.bulk_update_counters_by_article_id([article1.id, article2.id])

      article1.reload
      article2.reload

      expect(article1.feed_success_score).to eq(0.0) # Should remain uninitialized
      expect(article1.feed_impressions_count).to eq(0)
      expect(article1.feed_clicks_count).to eq(0)

      # Scores and counters for article2 should remain uninitialized
      expect(article2.feed_success_score).to eq(0.0)
      expect(article2.feed_impressions_count).to eq(0)
      expect(article2.feed_clicks_count).to eq(0)
    end
  end
end
