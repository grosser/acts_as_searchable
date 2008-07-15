class Comment < ActiveRecord::Base
  acts_as_searchable :if_changed => [ :article_id ], :seachable_fields => [:body],:attributes=>{:body_set=>nil}
  belongs_to :article, :counter_cache => true

  def body_set
    @bodya
  end
  def body_set=(text)
    @bodya=text
  end
end