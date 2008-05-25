class Notification < ActiveRecord::Base
  acts_as_searchable :searchable_fields => [:body]
end

class CommentNotification < Notification
end

class DeepCommentNotification < CommentNotification
end