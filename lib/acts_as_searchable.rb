# Copyright (c) 2006 Patrick Lenz
# 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# Thanks: Rick Olson (technoweenie) for his numerous plugins that served
# as an example

require 'vendor/estraierpure'

module ActiveRecord #:nodoc:
  module Acts #:nodoc:
    # Specify this act if you want to provide fulltext search capabilities to your model via Hyper Estraier. This
    # assumes a setup and running Hyper Estraier node accessible through the HTTP API provided by the EstraierPure
    # Ruby module (which is bundled with this plugin).
    #
    # The act supplies appropriate hooks to insert, update and remove documents from the index when you update your
    # model data, create new objects or remove them from your database. For the initial indexing a convenience
    # class method <tt>reindex!</tt> is provided.
    #
    # Example:
    #
    #   class Article < ActiveRecord::Base
    #     acts_as_searchable :searchable_fields => :body
    #   end
    #
    #   Article.reindex!
    #
    # As soon as your model data has been indexed you can make use of the <tt>fulltext_search</tt> class method
    # to search the index and get back instantiated matches.
    #
    #   results = Article.fulltext_search('rails')
    #   results.size        # => 3
    #
    #   results.first.class # => Article
    #   results.first.body  # => "Ruby on Rails is an open-source web framework"
    #
    # Connectivity configuration can be either inherited from conventions or setup globally in the Rails
    # database configuration file <tt>config/database.yml</tt>.
    #
    # Example:
    #
    #   development:
    #     adapter: mysql
    #     database: rails_development
    #     host: localhost
    #     user: root
    #     password:
    #     estraier:
    #       host: localhost
    #       user: admin
    #       password: admin
    #       port: 1978
    #       node: development
    #
    # That way you can configure separate connections for each environment. The values shown above represent the
    # defaults. If you don't need to change any of these it is safe to not specify the <tt>estraier</tt> hash
    # at all.
    #
    # See ActiveRecord::Acts::Searchable::ClassMethods#acts_as_searchable for per-model configuration options
    #
    module Searchable
      def self.included(base) #:nodoc:
        base.extend ClassMethods        
      end
      
      module ClassMethods
        # == Configuration options
        #
        # * <tt>searchable_fields</tt> - Fields to provide searching and indexing for
        # * <tt>attributes</tt> - Additional attributes to store in Hyper Estraier with the appropriate method supplying the value (not found by pure text-search)
        # * <tt>if_changed</tt> - Extra list of attributes to add to the list of attributes that trigger an index update when changed
        # * <tt>quiet</tt> - raise(default) or log, if i cannot connect to HE ?
        #
        # Examples:
        #
        #   acts_as_searchable :attributes => { :title => nil, :blog => :blog_title }, :searchable_fields => [ :title, :body ]
        #
        # This would store the return value of the <tt>title</tt> method in the <tt>title</tt> attribute and the return value of the
        # <tt>blog_title</tt> method in the <tt>blog</tt> attribute. The contents of the <tt>title</tt> and <tt>body</tt> columns
        # would end up being indexed for searching.
        #
        # == Attribute naming
        #
        # Attributes that match the reserved names of the Hyper Estraier system attributes are mapped automatically. This is something
        # to keep in mind for custom ordering options or additional query constraints in <tt>fulltext_search</tt>
        # For a list of these attributes see <tt>EstraierPure::SYSTEM_ATTRIBUTES</tt> or visit:
        # 
        #   http://hyperestraier.sourceforge.net/uguide-en.html#attributes
        #
        # From the example above:
        #
        #   Model.fulltext_search('query', :order => '@title STRA')               # Returns results ordered by title in ascending order
        #   Model.fulltext_search('query', :attributes => 'blog STREQ poocs.net') # Returns results with a blog attribute of 'poocs.net'
        #
        def acts_as_searchable(options = {})
          return if self.included_modules.include?(ActiveRecord::Acts::Searchable::ActMethods)

          send :include, ActiveRecord::Acts::Searchable::ActMethods
          
          #each searchable class gets their estraier-adapter (estraier)
          #these must not be overwritten by subclasses that are searchable too
          #so using an cattr_accessor estraier will not work
          cattr_accessor :estraiers
          self.estraiers ||= {}
          self.estraiers[self] = EstraierPure::EstraierAdapter.new(self)
          
          estraier.searchable_fields    = options[:searchable_fields] || []
          estraier.attributes_to_store  = options[:attributes] || {}
          update_if_changed             = options[:if_changed] || []
          estraier.quiet                = options[:quiet] || false
          
          send :attr_accessor, :estraier_changed_attributes

          class_eval do
            after_update  :update_index
            after_create  :add_to_index
            after_destroy :remove_from_index
            after_save    :estraier_clear_changed_attributes

            (update_if_changed + estraier.searchable_fields + estraier.attributes_to_store.collect { |attribute, method| method or attribute }).each do |attr_name|
              define_method("#{attr_name}=") do |value|
                estraier_write_changed_attribute attr_name, value
              end
            end

            self.estraier.connect
          end
        end
        
        #we cannot store estraier in a class variable, since it would be overwritten by child classes
        #=> define 1 estraier for every searchable class, and return it also for child classes
        def estraier
          find_estraier_for = self
          while true
            if estraiers[find_estraier_for]
              current_estraier = estraiers[find_estraier_for] 
              current_estraier.ar_class = self
              current_estraier.ar_subclasses = subclasses #protected
              return current_estraier
            end
            find_estraier_for = find_estraier_for.base_class
          end
        end

        # Perform a fulltext search against the Hyper Estraier index.
        #
        # Options taken:
        # * <tt>limit</tt>       - Maximum number of records to retrieve (default: <tt>100</tt>)
        # * <tt>offset</tt>      - Number of records to skip (default: <tt>0</tt>)
        # * <tt>order</tt>       - Hyper Estraier expression to sort the results (example: <tt>@title STRA</tt>, default: ordering by score)
        # * <tt>attributes</tt>  - String to append to Hyper Estraier search query
        # * <tt>raw_matches</tt> - Returns raw Hyper Estraier documents instead of instantiated AR objects
        # * <tt>find</tt>        - Options to pass on to the <tt>ActiveRecord::Base#find</tt> call
        # * <tt>count</tt>       - Set this to <tt>true</tt> if you're using <tt>fulltext_search</tt> in conjunction with <tt>ActionController::Pagination</tt> to return the number of matches only
        #
        # Examples:
        # 
        #   Article.fulltext_search("biscuits AND gravy")
        #   Article.fulltext_search("biscuits AND gravy", :limit => 15, :offset => 14)
        #   Article.fulltext_search("biscuits AND gravy", :attributes => "tag STRINC food")
        #   Article.fulltext_search("biscuits AND gravy", :attributes => ["tag STRINC food", "@title STRBW Biscuit"])
        #   Article.fulltext_search("biscuits AND gravy", :order => "@title STRA")
        #   Article.fulltext_search("biscuits AND gravy", :raw_matches => true)
        #   Article.fulltext_search("biscuits AND gravy", :find => { :order => :title, :include => :comments })
        #
        # Consult the Hyper Estraier documentation on proper query syntax:
        # 
        #   http://hyperestraier.sourceforge.net/uguide-en.html#searchcond
        #
        def fulltext_search(query = "", options = {})
          return [] unless estraier.connection_active?
          options = estraier.sanitize_options(options)
          cond = estraier.set_search_condition(estraier.create_condition,query, options)

          matches = nil
          seconds = Benchmark.realtime do
            result = estraier.connection.search(cond, 1);
            return (result.doc_num rescue 0) if options[:count]
            return [] unless result
            matches = estraier.get_docs_from(result)
            return matches if options[:raw_matches]
          end

          logger.debug(
            connection.send(:format_log_entry, 
              "#{self.to_s} Search for '#{query}' (#{sprintf("%f", seconds)})",
              "Condition: #{cond.to_s}"
            )
          )
            
          matches.blank? ? [] : find(matches.collect { |m| m.attr('db_id') }, options[:find])
        end
        
        # Clear all entries from index
        def clear_index!
          return unless estraier.connection_active?
          estraier.index.each { |d| estraier.connection.out_doc(d.attr('@id')) unless d.nil? }
        end
        
        # Peform a full re-index of the model data for this model
        def reindex!
          return unless estraier.connection_active?
          find(:all).each { |r| r.update_index(true) }
        end
      end
      
      module ActMethods
        def self.included(base) #:nodoc:
          base.extend ClassMethods
        end
        
        # Update index for current instance
        def update_index(force = false)
          return unless estraier_changed? or force
          remove_from_index
          add_to_index
        end
        
        # Retrieve index record for current model object
        def estraier_doc
          cond = self.class.estraier.create_condition
          cond.add_attr("db_id STREQ #{self.id}")
          result = self.class.estraier.connection.search(cond, 1)
          return unless result and result.doc_num > 0
          self.class.estraier.get_doc_from(result)
        end
        
        # If called with no parameters, gets whether the current model has changed and needs to updated in the index.
        # If called with a single parameter, gets whether the parameter has changed.
        def estraier_changed?(attr_name = nil)
          estraier_changed_attributes and (attr_name.nil? ?
            (not estraier_changed_attributes.length.zero?) : (estraier_changed_attributes.include?(attr_name.to_s)) )
        end
        
        protected
        
        def estraier_clear_changed_attributes #:nodoc:
          self.estraier_changed_attributes = []
        end
        
        def estraier_write_changed_attribute(attr_name, attr_value) #:nodoc:
          (self.estraier_changed_attributes ||= []) << attr_name.to_s unless self.estraier_changed?(attr_name) or self.send(attr_name) == attr_value
          write_attribute(attr_name.to_s, attr_value)
        end

        def add_to_index #:nodoc:
          seconds = Benchmark.realtime { self.class.estraier.connection.put_doc(document_object) }
          logger.debug "#{self.class.to_s} [##{id}] Adding to index (#{sprintf("%f", seconds)})"
          
        end
        
        def remove_from_index #:nodoc:
          return unless doc = estraier_doc
          seconds = Benchmark.realtime { self.class.estraier.connection.out_doc(doc.attr('@id')) }
          logger.debug "#{self.class.to_s} [##{id}] Removing from index (#{sprintf("%f", seconds)})"
        end
        
        def document_object #:nodoc:
          doc = EstraierPure::Document::new
          doc.add_attr('db_id', "#{id}")
          doc.add_attr('type', "#{self.class.to_s}")
          # Use type instead of self.class.subclasses as the latter is a protected method
          unless self.class.base_class == self.class and not attribute_names.include?("type")
            doc.add_attr("type_base", "#{ self.class.estraier.searchable_base_class.to_s }")
          end
          doc.add_attr('@uri', "/#{self.class.to_s}/#{id}")
          
          unless self.class.estraier.attributes_to_store.blank?
            self.class.estraier.attributes_to_store.each do |attribute, method|
              value = send(method || attribute)
              value = value.xmlschema if value.is_a?(Time)
              doc.add_attr(attribute_name(attribute), value.to_s)
            end
          end

          self.class.estraier.searchable_fields.each do |f|
            doc.add_text(send(f).to_s)
          end

          doc          
        end
        
        def attribute_name(attribute)
          EstraierPure::SYSTEM_ATTRIBUTES.include?(attribute.to_s) ? "@#{attribute}" : "#{attribute}"
        end
      end
    end
  end
end

module EstraierPure
  class EstraierAdapter
    VALID_FULLTEXT_OPTIONS = [:limit, :offset, :order, :attributes, :raw_matches, :find, :count]
    attr_accessor :quiet, :password, :host, :port, :user, :node, :connection,
      :searchable_fields, :attributes_to_store,
      :ar_class, :ar_subclasses
    
    #keeps track of which classes are searchable
    #since when a subclass is not searchable, we need to know which of its parents is
    cattr_accessor :searchable_classes

    def initialize(searchable_class)
      self.ar_class = searchable_class #temporary for initialisation
      self.searchable_classes ||=[]
      self.searchable_classes << searchable_class
      
      self.node        = config['node'] || RAILS_ENV
      self.host        = config['host'] || 'localhost'
      self.port        = config['port'] || 1978
      self.user        = config['user'] || 'admin'
      self.password    = config['password'] || 'admin'
    end

    def connect #:nodoc:
      self.connection = EstraierPure::Node::new
      connection.set_url("http://#{host}:#{port}/node/#{node}")
      connection.set_auth(user, password)
    end
    
    def sanitize_options(options)
      options.reverse_merge!(:limit => 100, :offset => 0)
      options.assert_valid_keys(VALID_FULLTEXT_OPTIONS)
      options[:find] ||= {}
      [ :limit, :offset ].each { |k| options[:find].delete(k) }
      options
    end
    
    def create_condition
      cond = EstraierPure::Condition::new
      cond.set_options(EstraierPure::Condition::SIMPLE | EstraierPure::Condition::USUAL)
      
      #search for type_base(=>all subclasses) if class is searchable and has subclasses
      if searchable_base_class == ar_class and !ar_subclasses.blank? 
        cond.add_attr("type_base STREQ #{ searchable_base_class.to_s }")
      else
        cond.add_attr("type STREQ #{ ar_class.to_s }")
      end
      cond
    end
    
    #find first class in hirachy that is searchable
    def searchable_base_class
      current_class = ar_class
      while true
        return current_class if searchable_classes.include? current_class
        current_class = current_class.base_class
      end
    end
    
    def set_search_condition(cond,query, options)
      cond.set_phrase query
      [options[:attributes]].flatten.reject { |a| a.blank? }.each do |attr|
        cond.add_attr attr
      end
      cond.set_max   options[:limit]
      cond.set_skip  options[:offset]
      cond.set_order options[:order] if options[:order]
      cond
    end
    
    #raise/log depending on quiet setting
    def connection_active?
      connection.name
      unless connection.status == 200
        if quiet
          logger.error "Can't connect to HyperEstraier Node."
        else
          raise "Can't connect to HyperEstraier Node."
        end
        return false
      end
      return true
    end
    
    def index #:nodoc:
      cond = EstraierPure::Condition::new
      cond.add_attr("type STREQ #{searchable_base_class.to_s}")
      result = connection.search(cond, 1)
      docs = get_docs_from(result)
      docs
    end
    
    def config #:nodoc:
      ar_class.configurations[RAILS_ENV]['estraier'] or {}
    end
    
    def get_doc_from(result) #:nodoc:
      get_docs_from(result).first
    end
    
    def get_docs_from(result) #:nodoc:
      docs = []
      for i in 0...result.doc_num
        docs << result.get_doc(i)
      end
      docs
    end   
  end
end

ActiveRecord::Base.send :include, ActiveRecord::Acts::Searchable

module EstraierPure
  unless defined?(SYSTEM_ATTRIBUTES)
    SYSTEM_ATTRIBUTES = %w( uri digest cdate mdate adate title author type lang genre size weight misc )
  end
  
  class Node
    def list
      return false unless @url
      turl = @url + "/list"
      reqheads = [ "Content-Type: application/x-www-form-urlencoded" ]
      reqheads.push("Authorization: Basic " + Utility::base_encode(@auth)) if @auth
      reqbody = ""
      resbody = StringIO::new
      rv = Utility::shuttle_url(turl, @pxhost, @pxport, @timeout, reqheads, reqbody, nil, resbody)
      @status = rv
      return nil if rv != 200
      lines = resbody.string.split(/\n/)
      lines.collect { |l| val = l.split(/\t/) and { :id => val[0], :uri => val[1], :digest => val[2] } }
    end
  end
  
  class Condition
    def to_s
      "phrase: %s, attrs: %s, max: %s, options: %s, order: %s, skip: %s" % [ phrase, attrs * ', ', max, options, order, skip ]
    end
  end
end
