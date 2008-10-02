module Merb
  class Router
    class Behavior
      module Resources

        # Behavior#+resources+ is a route helper for defining a collection of
        # RESTful resources. It yields to a block for child routes.
        #
        # ==== Parameters
        # name<String, Symbol>:: The name of the resources
        # options<Hash>::
        #   Ovverides and parameters to be associated with the route
        #
        # ==== Options (options)
        # :namespace<~to_s>: The namespace for this route.
        # :name_prefix<~to_s>:
        #   A prefix for the named routes. If a namespace is passed and there
        #   isn't a name prefix, the namespace will become the prefix.
        # :controller<~to_s>: The controller for this route
        # :collection<~to_s>: Special settings for the collections routes
        # :member<Hash>:
        #   Special settings and resources related to a specific member of this
        #   resource.
        # :keys<Array>:
        #   A list of the keys to be used instead of :id with the resource in the order of the url.
        # :singular<Symbol>
        #
        # ==== Block parameters
        # next_level<Behavior>:: The child behavior.
        #
        # ==== Returns
        # Array::
        #   Routes which will define the specified RESTful collection of resources
        #
        # ==== Examples
        #
        #  r.resources :posts # will result in the typical RESTful CRUD
        #    # lists resources
        #    # GET     /posts/?(\.:format)?      :action => "index"
        #    # GET     /posts/index(\.:format)?  :action => "index"
        #
        #    # shows new resource form
        #    # GET     /posts/new                :action => "new"
        #
        #    # creates resource
        #    # POST    /posts/?(\.:format)?,     :action => "create"
        #
        #    # shows resource
        #    # GET     /posts/:id(\.:format)?    :action => "show"
        #
        #    # shows edit form
        #    # GET     /posts/:id/edit        :action => "edit"
        #
        #    # updates resource
        #    # PUT     /posts/:id(\.:format)?    :action => "update"
        #
        #    # shows deletion confirmation page
        #    # GET     /posts/:id/delete      :action => "delete"
        #
        #    # destroys resources
        #    # DELETE  /posts/:id(\.:format)?    :action => "destroy"
        #
        #  # Nesting resources
        #  r.resources :posts do |posts|
        #    posts.resources :comments
        #  end
        #---
        # @public
        def resources(name, *args, &block)
          name       = name.to_s
          options    = extract_options_from_args!(args) || {}
          singular   = options[:singular] ? options[:singular].to_s : Extlib::Inflection.singularize(name)
          klass      = args.first ? args.first.to_s : Extlib::Inflection.classify(singular)
          keys       = [ options.delete(:keys) || :id ].flatten
          params     = { :controller => options.delete(:controller) || name }
          collection = options.delete(:collection) || {}
          member     = { :edit => :get, :delete => :get }.merge(options.delete(:member) || {})

          # Try pulling :namespace out of options for backwards compatibility
          options[:name_prefix]       ||= nil # Don't use a name_prefix if not needed
          options[:resource_prefix]   ||= nil # Don't use a resource_prefix if not needed
          options[:controller_prefix] ||= options.delete(:namespace)

          self.namespace(name, options).to(params) do |resource|
            root_keys = keys.map { |k| ":#{k}" }.join("/")
            
            # => index
            resource.match("(/index)(.:format)", :method => :get).to(:action => "index").
              name(name).register_resource(name)
              
            # => create
            resource.match("(.:format)", :method => :post).to(:action => "create")
            
            # => new
            resource.match("/new(.:format)", :method => :get).to(:action => "new").
              name("new", singular).register_resource(name, "new")

            # => user defined collection routes
            collection.each_pair do |action, method|
              action = action.to_s
              resource.match("/#{action}(.:format)", :method => method).to(:action => "#{action}").
                name(action, name).register_resource(name, action)
            end

            # => show
            resource.match("/#{root_keys}(.:format)", :method => :get).to(:action => "show").
              name(singular).register_resource(klass)

            # => user defined member routes
            member.each_pair do |action, method|
              action = action.to_s
              resource.match("/#{root_keys}/#{action}(.:format)", :method => method).
                to(:action => "#{action}").name(action, singular).register_resource(klass, action)
            end

            # => update
            resource.match("/#{root_keys}(.:format)", :method => :put).
              to(:action => "update")
              
            # => destroy
            resource.match("/#{root_keys}(.:format)", :method => :delete).
              to(:action => "destroy")

            if block_given?
              nested_keys = keys.map { |k| k.to_s == "id" ? ":#{singular}_id" : ":#{k}" }.join("/")
              resource.options(:name_prefix => singular, :resource_prefix => klass).match("/#{nested_keys}", &block)
            end

          end
        end

        # Behavior#+resource+ is a route helper for defining a singular RESTful
        # resource. It yields to a block for child routes.
        #
        # ==== Parameters
        # name<String, Symbol>:: The name of the resource.
        # options<Hash>::
        #   Overides and parameters to be associated with the route.
        #
        # ==== Options (options)
        # :namespace<~to_s>: The namespace for this route.
        # :name_prefix<~to_s>:
        #   A prefix for the named routes. If a namespace is passed and there
        #   isn't a name prefix, the namespace will become the prefix.
        # :controller<~to_s>: The controller for this route
        #
        # ==== Block parameters
        # next_level<Behavior>:: The child behavior.
        #
        # ==== Returns
        # Array:: Routes which define a RESTful single resource.
        #
        # ==== Examples
        #
        #  r.resource :account # will result in the typical RESTful CRUD
        #    # shows new resource form      
        #    # GET     /account/new                :action => "new"
        #
        #    # creates resource      
        #    # POST    /account/?(\.:format)?,     :action => "create"
        #
        #    # shows resource      
        #    # GET     /account/(\.:format)?       :action => "show"
        #
        #    # shows edit form      
        #    # GET     /account//edit           :action => "edit"
        #
        #    # updates resource      
        #    # PUT     /account/(\.:format)?       :action => "update"
        #
        #    # shows deletion confirmation page      
        #    # GET     /account//delete         :action => "delete"
        #
        #    # destroys resources      
        #    # DELETE  /account/(\.:format)?       :action => "destroy"
        #
        # You can optionally pass :namespace and :controller to refine the routing
        # or pass a block to nest resources.
        #
        #   r.resource :account, :namespace => "admin" do |account|
        #     account.resources :preferences, :controller => "settings"
        #   end
        # ---
        # @public
        def resource(name, *args, &block)
          name    = name.to_s
          options = extract_options_from_args!(args) || {}
          params  = { :controller => options.delete(:controller) || name.pluralize }

          options[:name_prefix]       ||= nil # Don't use a name_prefix if not needed
          options[:resource_prefix]   ||= nil # Don't use a resource_prefix if not needed
          options[:controller_prefix] ||= options.delete(:namespace)

          self.namespace(name, options).to(params) do |resource|
            resource.match("(.:format)",        :method => :get   ).to(:action => "show"   ).name(name).register_resource(name)
            resource.match("(.:format)",        :method => :post  ).to(:action => "create" )
            resource.match("(.:format)",        :method => :put   ).to(:action => "update" )
            resource.match("(.:format)",        :method => :delete).to(:action => "destroy")
            resource.match("/new(.:format)",    :method => :get   ).to(:action => "new"    ).name(:new,    name).register_resource(name, "new")
            resource.match("/edit(.:format)",   :method => :get   ).to(:action => "edit"   ).name(:edit,   name).register_resource(name, "edit")
            resource.match("/delete(.:format)", :method => :get   ).to(:action => "delete" ).name(:delete, name).register_resource(name, "delete")

            resource.options(:name_prefix => name, :resource_prefix => name,  &block) if block_given?
          end
        end
        
      protected
      
        def register_resource(*key)
          key = [@options[:resource_prefix], key].flatten.compact
          @route.resource = key
          self
        end

      end

      include Resources
    end
  end
end