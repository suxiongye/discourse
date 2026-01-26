# frozen_string_literal: true

module PageObjects
  module Components
    class DTemplatesPanel < PageObjects::Components::Base
      include SystemHelpers

      PANEL_SELECTOR = ".d-templates-container"

      def open_with_keyboard_shortcut
        send_keys([PLATFORM_KEY_MODIFIER, :shift, "i"])
      end

      def open?
        has_css?(PANEL_SELECTOR) && finished_loading?
      end

      def finished_loading?
        has_no_css?("#{PANEL_SELECTOR} .spinner")
      end

      def select_template(template)
        find("#template-item-#{template.id} .templates-apply").click
      end

      def tag_drop
        PageObjects::Components::SelectKit.new("#{PANEL_SELECTOR} .tag-drop")
      end

      def has_template?(template)
        has_css?("#template-item-#{template.id}")
      end

      def has_no_template?(template)
        has_no_css?("#template-item-#{template.id}")
      end

      def template_count
        all("#{PANEL_SELECTOR} .template-item").count
      end
    end
  end
end
