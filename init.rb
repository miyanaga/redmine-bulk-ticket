Redmine::Plugin.register :redmine_bulk_ticket do
  name 'Redmine Bulk Ticket plugin'
  author 'Kunihiko Miyanaga'
  description 'Supports bulk ticketing.'
  version '0.0.1'
  url 'https://github.com/miyanaga/redmine-bulk-ticket'
  author_url 'http://www.ideamans.com/'

  project_module :bulk_ticket do
    permission :bulk_ticket, :issues => :bulk_ticket
  end
end

require 'issue'
require 'issue_query'
require 'queries_helper'

class IssueQuery
  self.available_columns << QueryColumn.new(:sub_issues, :inline => false)
end

module QueriesHelper
  def self.included(mod)
    mod.class_eval do
      alias_method_chain :column_value, :my_column_value
    end
  end

  def column_value_with_my_column_value(column, issue, value)
    if column.name == :sub_issues
      value
    else
      column_value_without_my_column_value(column, issue, value)
    end
  end
end

class SubIssuesWrapper
  include ERB::Util
  include ApplicationHelper
  include ActionView::Helpers::FormTagHelper
  include ActionDispatch::Routing
  include Rails.application.routes.url_helpers

  def initialize(issue)
    @issue = issue
  end

  def render
    return nil if @issue.children.nil? or @issue.children.length < 1

    s = '<table class="list issues">'
    @issue.children.each do |child|
      css = "issue issue-#{child.id}"
      s << content_tag('tr',
             content_tag('td', h(child.project.name)) +
             content_tag('td', h(child.status)) +
             content_tag('td', child.assigned_to.name) +
             content_tag('td', progress_bar(child.done_ratio, :width => '80px')),
             :class => css)
    end
    s << '</table>'
    html = s.html_safe
    html
  end
end

class Issue
  def sub_issues
    SubIssuesWrapper.new(self).render
  end
end

class BulkTicketHooks < Redmine::Hook::Listener
  include ActionView::Helpers
  include ActionDispatch::Routing
  include Rails.application.routes.url_helpers

  def self.enabled_bulk_ticket_module(project)
  end

  def controller_issues_edit_after_save(context = {})
    current_project = context[:issue].project
    return unless current_project.module_enabled? :bulk_ticket
    return unless User.current.allowed_to? :bulk_ticket, current_project

    params = context[:params]
    values = params[:issue]
    orig = context[:issue]

    msg = I18n.t(:bulk_ticket_new_desc, {
      :url => url_for(:controller => 'issues', :action => 'show', :id => orig.id),
      :id => orig.id
    })

    binding.pry

    if values[:subprojects].present?
      values[:subprojects].keys.each do |pid|
        project = Project.find(pid)
        issue = Issue.new(parent_issue_id: orig.id, root_id: orig.root_id)
        issue.attributes = orig.attributes.dup.except("id", "root_id", "parent_id", "lft", "rgt", "created_on", "updated_on")
        issue.description = msg
        issue.project = project
        issue.save!
      end
    end

    if values[:members].present?
      values[:members].keys.each do |uid|
        user = User.find(uid)
        issue = Issue.new(parent_issue_id: orig.id, root_id: orig.root_id)
        issue.attributes = orig.attributes.dup.except("id", "root_id", "parent_id", "lft", "rgt", "created_on", "updated_on")
        issue.description = msg
        issue.assigned_to_id = user.id
        issue.save!
      end
    end
  end

  class ViewHook < Redmine::Hook::ViewListener
    def view_issues_form_details_bottom(context = {})
      return unless context[:project].module_enabled? :bulk_ticket
      return unless User.current.allowed_to? :bulk_ticket, context[:project]

      issue = context[:issue]
      return if issue.id.nil?

      project = context[:project]
      subprojects = project.children.visible.all
      members = project.members.map(&:user)

      subproject_relations = {}
      member_relations = {}

      issue.children.each do |c|
        if c.project.id != project.id
          subproject_relations[c.project.id] = true
        elsif c.assigned_to.present?
          c.assigned_to.members.map(&:user).each do |u|
            member_relations[u.id] = true
          end
        end
      end

      context[:controller].send :render_to_string, 
        partial: 'issues/bulk_ticket',
        locals: {
          context: context,
          subprojects: subprojects,
          subproject_relations: subproject_relations,
          members: members,
          member_relations: member_relations,
        }
    end
  end
end