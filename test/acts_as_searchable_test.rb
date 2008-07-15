require File.join(File.dirname(__FILE__), 'abstract_unit')
require File.join(File.dirname(__FILE__), 'fixtures/article')
require File.join(File.dirname(__FILE__), 'fixtures/comment')
require File.join(File.dirname(__FILE__), 'fixtures/notification')

require 'rubygems'
require 'digest/sha1'

class ActsAsSearchableTest < Test::Unit::TestCase
  fixtures :articles, :comments, :notifications
  @@indexed = false

  def test_defaults
    #these will not work if something else is entered in config/database.yml 
#    assert_equal 'test',      Comment.estraier.node
#    assert_equal 'localhost', Comment.estraier.host
#    assert_equal 1978,        Comment.estraier.port
#    assert_equal 'admin',     Comment.estraier.user
#    assert_equal 'admin',     Comment.estraier.password
    assert_equal [],          Comment.estraier.searchable_fields
    assert_equal false,       Comment.estraier.quiet
  end
  
  def test_hooks_presence
    assert Article.after_update.include?(:update_index)
    assert Article.after_create.include?(:add_to_index)
    assert Article.after_destroy.include?(:remove_from_index)    
  end
  
  def test_connection
    assert_kind_of EstraierPure::Node, Article.estraier.connection
  end
  
  def test_reindex!
    Article.clear_index!
    @@indexed = false
    assert_equal 0, Article.estraier.index.size
    reindex!
    assert_equal Article.count, Article.estraier.index.size
  end
  
  def test_clear_index!
    Article.clear_index!
    assert_equal 0, Article.estraier.index.size
    @@indexed = false
  end
  
  def test_after_update_hook
    articles(:first).update_attribute :body, "updated via tests"
    doc = articles(:first).estraier_doc
    assert_equal articles(:first).id.to_s,    doc.attr('db_id')
    assert_equal articles(:first).class.to_s, doc.attr('type')
    assert Article.estraier.connection.get_doc(doc.attr('@id')).texts.include?(articles(:first).body)
  end
  
  def test_after_create_hook
    a = Article.create :title => "title created via tests", :body => "body created via tests", :tags => "ruby weblog"
    doc = a.estraier_doc
    assert_equal a.id.to_s,    doc.attr('db_id')
    assert_equal a.class.to_s, doc.attr('type')
    assert_equal a.tags,       doc.attr('custom_attribute')
    assert_equal a.title,      doc.attr('@title')
    assert_equal Article.estraier.connection.get_doc(doc.attr('@id')).texts, [ a.title, a.body ]
  end
  
  def test_after_destroy_hook
    articles(:first).destroy
    assert articles(:first).estraier_doc.blank?
  end

  def test_nil_body
    # TODO also test nil attr's
    assert_nothing_raised() do
      articles(:first).update_attribute :body, nil
      Article.create(:title => "nil body test", :body => nil)
    end
  end
  
  def test_fulltext_search
    reindex!
    assert_equal 1, Article.fulltext_search('mauris', :count => true)
  end
  
  def test_fulltext_search_with_wildcard
    reindex!
    assert_equal 1, Article.fulltext_search('mau*').size
    #retest...this often Fails when timeout is too short
  end

  def test_fulltext_search_with_attributes
    reindex!
    results = Article.fulltext_search('', :attributes => "custom_attribute STRINC rails")
    assert_equal 2, results.size
    assert_equal true, results.include?(articles(:second)) 
    assert_equal true, results.include?(articles(:third))
  end

  def test_fulltext_search_with_attributes_array
    reindex!
    assert_equal [articles(:third)], Article.fulltext_search('', :attributes => ["custom_attribute STRINC rails", "@title STRBW lorem"])
  end

  def test_fulltext_search_with_number_attribute
    reindex!
    assert_equal [articles(:first)], Article.fulltext_search('', :attributes => "comments_count NUMGE 1")
  end

  def test_fulltext_search_with_date_attribute
    reindex!
    assert_equal [articles(:third)], Article.fulltext_search('ipsum', :attributes => "@cdate NUMLE #{1.year.from_now.xmlschema}")
  end

  def test_fulltext_search_with_ordering
    reindex!
    assert_equal %w(1 2 3), Article.fulltext_search('', :order => 'db_id NUMA', :raw_matches => true).collect { |d| d.attr('db_id') }
    assert_equal %w(3 2 1), Article.fulltext_search('', :order => 'db_id NUMD', :raw_matches => true).collect { |d| d.attr('db_id') }
  end

  def test_fulltext_search_with_pagination
    reindex!
    assert_equal %w(1 2), Article.fulltext_search('', :order => 'db_id NUMA', :raw_matches => true, :limit => 2).collect { |d| d.attr('db_id') }
    assert_equal %w(3 2), Article.fulltext_search('', :order => 'db_id NUMD', :raw_matches => true, :limit => 2).collect { |d| d.attr('db_id') }
    assert_equal %w(2 3), Article.fulltext_search('', :order => 'db_id NUMA', :raw_matches => true, :limit => 2, :offset => 1).collect { |d| d.attr('db_id') }
    assert_equal %w(2 1), Article.fulltext_search('', :order => 'db_id NUMD', :raw_matches => true, :limit => 2, :offset => 1).collect { |d| d.attr('db_id') }
  end

  def test_fulltext_search_with_no_results
    reindex!
    result = Article.fulltext_search('i do not exist')
    assert_kind_of Array, result
    assert_equal 0, result.size
  end
  
  def test_fulltext_search_with_find
    reindex!
    assert_equal %w(1 3), Article.fulltext_search('', :find => { :order => "title ASC" }).collect { |a| a.id.to_s }.first(2)
    assert_equal %w(2 3), Article.fulltext_search('', :find => { :order => "title DESC"}).collect { |a| a.id.to_s }.first(2)
  end
  
  def test_fulltext_with_invalid_find_parameters
    reindex!
    assert_nothing_raised { Article.fulltext_search('', :limit => 3, :find => { :limit => 1 } ) }
  end

  def test_does_not_overwrite_attrs
    comments(:first).body_set='NEW'
    assert_equal comments(:first).body_set,'NEW'
#    assert comments(:first).estraier_changed?
  end

  def test_act_if_changed
    assert ! comments(:first).estraier_changed?
    comments(:first).article_id = 123
    assert comments(:first).estraier_changed?
  end
  
  def test_act_changed_attributes
    assert ! articles(:first).estraier_changed?
    articles(:first).tags = "123" # Covers :attributes
    assert articles(:first).estraier_changed?
    
    assert ! articles(:second).estraier_changed?
    articles(:second).body = "123" # Covers :searchable_fields
    assert articles(:second).estraier_changed?
    
    assert articles(:second).save
    assert ! articles(:second).estraier_changed?
  end

  def test_fulltext_with_count
    reindex!
    assert_equal 3, Article.fulltext_search('', :count => true)
  end
  
  def test_type_base_condition
    assert Article.estraier.create_condition.attrs.include?("type STREQ #{Article.to_s}")
    assert Notification.estraier.create_condition.attrs.include?("type_base STREQ #{Notification.to_s}")
    assert CommentNotification.estraier.create_condition.attrs.include?("type STREQ #{CommentNotification.to_s}")
    assert DeepCommentNotification.estraier.create_condition.attrs.include?("type STREQ #{DeepCommentNotification.to_s}")
  end
  
  def test_fulltext_search_with_sti
    reindex!
    assert_equal 3, Notification.fulltext_search('', :count => true)
    #TODO? this should theoretically find 2, since DeepCommentNotification is a baseclass
    #but since CommentNotification is not searchable itself, it will only find record with 
    #the exact same type
    assert_equal 1, CommentNotification.fulltext_search('', :count => true)
    assert notifications(:second).estraier_doc.attr_names.include?("type_base")
  end

  protected
  
  def reindex!
    unless @@indexed
      Article.reindex!
      Notification.reindex!
      @@indexed = true
      sleep 10
    end
  end
end
