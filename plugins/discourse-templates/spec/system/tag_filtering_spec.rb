# frozen_string_literal: true

RSpec.describe "Filtering templates by tags", type: :system do
  fab!(:current_user, :user)
  fab!(:templates_category, :category)
  fab!(:tag_ruby) { Fabricate(:tag, name: "ruby") }
  fab!(:tag_javascript) { Fabricate(:tag, name: "javascript") }

  fab!(:template_ruby) { Fabricate(:template_item, category: templates_category, tags: [tag_ruby]) }

  fab!(:template_javascript) do
    Fabricate(:template_item, category: templates_category, tags: [tag_javascript])
  end

  fab!(:template_both_tags) do
    Fabricate(:template_item, category: templates_category, tags: [tag_ruby, tag_javascript])
  end

  fab!(:template_no_tags) { Fabricate(:template_item, category: templates_category) }

  fab!(:topic) { Fabricate(:post).topic }

  let(:composer) { PageObjects::Components::Composer.new }
  let(:templates_panel) { PageObjects::Components::DTemplatesPanel.new }
  let(:topic_page) { PageObjects::Pages::Topic.new }

  before do
    SiteSetting.discourse_templates_enabled = true
    SiteSetting.discourse_templates_categories = templates_category.id.to_s
    SiteSetting.tagging_enabled = true
    sign_in(current_user)
  end

  context "when filtering templates" do
    it "filters by tag and shows correct templates" do
      topic_page.visit_topic(topic)
      topic_page.click_reply_button
      composer.focus

      templates_panel.open_with_keyboard_shortcut
      expect(templates_panel).to be_open
      expect(templates_panel.template_count).to eq(4)

      templates_panel.tag_drop.expand
      templates_panel.tag_drop.select_row_by_name("ruby")

      expect(templates_panel).to have_template(template_ruby)
      expect(templates_panel).to have_template(template_both_tags)
      expect(templates_panel).to have_no_template(template_javascript)
      expect(templates_panel).to have_no_template(template_no_tags)
      expect(templates_panel.template_count).to eq(2)

      templates_panel.tag_drop.expand
      templates_panel.tag_drop.select_row_by_name("javascript")

      expect(templates_panel).to have_template(template_javascript)
      expect(templates_panel).to have_template(template_both_tags)
      expect(templates_panel).to have_no_template(template_ruby)
      expect(templates_panel).to have_no_template(template_no_tags)
      expect(templates_panel.template_count).to eq(2)

      templates_panel.tag_drop.expand
      templates_panel.tag_drop.select_row_by_value("no-tags")

      expect(templates_panel).to have_template(template_no_tags)
      expect(templates_panel).to have_no_template(template_ruby)
      expect(templates_panel).to have_no_template(template_javascript)
      expect(templates_panel).to have_no_template(template_both_tags)
      expect(templates_panel.template_count).to eq(1)

      templates_panel.tag_drop.expand
      templates_panel.tag_drop.select_row_by_value("all-tags")

      expect(templates_panel.template_count).to eq(4)
    end
  end
end
