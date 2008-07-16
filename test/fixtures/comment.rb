class Comment < ActiveRecord::Base
  belongs_to :article, :counter_cache => true
  acts_as_searchable :if_changed => [ :article_id ], :seachable_fields => [:body],:attributes=>{:body_set=>nil}

  def body_set
    @bodya
  end
  def body_set=(text)
    #FIXME still need this to make it work on real instance methods
    #calling acts_as_searchable after these methods helps only so far, that an alias is defined(alias method chain)
    #but strangely it is not used when calling body_set=
    estraier_write_changed_attribute 'body_set', text
    @bodya=text
  end
end