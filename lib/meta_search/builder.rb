require 'meta_search/model_compatibility'
require 'meta_search/exceptions'
require 'meta_search/where'
require 'meta_search/utility'

module MetaSearch
  class Builder
    include ModelCompatibility
    include Utility
    
    attr_reader :base, :attributes, :relation, :join_dependency
    delegate *RELATION_METHODS, :to => :relation

    def initialize(base, opts = {})
      @base = base
      @opts = HashWithIndifferentAccess[:exclude_associations => [], :exclude_attributes => []].merge(opts)
      @opts[:exclude_associations] = Array[@opts[:exclude_attributes]].flatten
      @opts[:exclude_attributes] = Array[@opts[:exclude_attributes]].flatten.map {|a| a.to_s}
      
      @association_names = @base.reflect_on_all_associations.map {|a| a.name} - @opts[:exclude_associations]
      @associations = {}
      @join_dependency = ActiveRecord::Associations::ClassMethods::JoinDependency.new(@base, [], nil)
      @attributes = {}
      @relation = @base.scoped
    end
    
    def column(attribute)
      @base.columns_hash[attribute.to_s] unless @opts[:exclude_attributes].include?(attribute.to_s)
    end
    
    def association(association)
      if @association_names.include?(association.to_sym)
        @associations[association.to_sym] ||= @base.reflect_on_association(association.to_sym)
      end
    end
    
    def association_column(association, column)
      self.association(association).klass.columns_hash[column.to_s] rescue nil
    end
    
    def build(opts)
      opts ||= {}
      @relation = @base.scoped
      opts.stringify_keys!
      opts = collapse_multiparameter_options(opts)
      assign_attributes(opts)
      self
    end
    
    private
    
    def method_missing(method_id, *args, &block)
      if match = method_id.to_s.match(/^(.*)\(([0-9]+).*\)$/)
        method_name, index = match.captures
        vals = self.send(method_name)
        vals.is_a?(Array) ? vals[index.to_i - 1] : nil
      elsif match = matches_attribute_method(method_id)
        condition, attribute, association = match.captures.reverse
        build_method(association, attribute, condition)
        self.send(preferred_method_name(method_id), *args)
      elsif match = matches_where_method(method_id)
        condition = match.captures.first
        build_where_method(condition, Where.get(condition))
        self.send(method_id, *args)
      else
        super
      end
    end
    
    def build_method(association, attribute, suffix)
      if association.blank?
        build_attribute_method(attribute, suffix)
      else
        build_association_method(association, attribute, suffix)
      end
    end
    
    def build_association_method(association, attribute, type)
      metaclass.instance_eval do        
        define_method("#{association}_#{attribute}_#{type}") do
          attributes["#{association}_#{attribute}_#{type}"]
        end
      
        define_method("#{association}_#{attribute}_#{type}=") do |val|
          attributes["#{association}_#{attribute}_#{type}"] = cast_attributes(association_type_for(association, attribute), val)
          if Where.valid_substitutions?(type, attributes["#{association}_#{attribute}_#{type}"])
            join = build_or_find_association(association)
            self.send("add_#{type}_where", join.aliased_table_name, attribute, attributes["#{association}_#{attribute}_#{type}"])
          end
        end
      end
    end
    
    def build_attribute_method(attribute, type)
      metaclass.instance_eval do
        define_method("#{attribute}_#{type}") do
          attributes["#{attribute}_#{type}"]
        end
      
        define_method("#{attribute}_#{type}=") do |val|
          attributes["#{attribute}_#{type}"] = cast_attributes(type_for(attribute), val)
          if Where.valid_substitutions?(type, attributes["#{attribute}_#{type}"])
            self.send("add_#{type}_where", @base.table_name, attribute, attributes["#{attribute}_#{type}"])
          end
        end
      end
    end
    
    def build_where_method(condition, opts)
      metaclass.instance_eval do
        define_method("add_#{condition}_where") do |table, attribute, *args|
          args.flatten! if looks_like_multiple_parameters(opts[:substitutions], args)
          @relation = @relation.where(
            "#{quote_table_name table}.#{quote_column_name attribute} " + 
            "#{opts[:condition]} #{opts[:substitutions]}", *format_params(opts[:formatter], *args)
          )
        end
      end
    end
    
    def format_params(formatter, *params)
      par = params.map {|p| formatter.call(p)}
    end
    
    def build_or_find_association(association)
      found_association = @join_dependency.join_associations.detect do |assoc|
        assoc.reflection.name == association.to_sym
      end
      unless found_association
        @relation = @relation.joins(association.to_sym)
        @join_dependency.send(:build, association.to_sym, @join_dependency.join_base)
        found_association = @join_dependency.join_associations.last
      end
      found_association
    end
    
    def matches_attribute_method(method_id)
      method_name = preferred_method_name(method_id)
      where = Where.get(method_id)
      return nil unless method_name && where
      match = method_name.match("^(.*)_(#{where[:name]})=?$")
      attribute, condition = match.captures
      if where[:types].include?(type_for(attribute))
        return match
      elsif match = matches_association(method_name, attribute, condition)
        association, attribute = match.captures
        return match if where[:types].include?(association_type_for(association, attribute))
      end
      nil
    end
    
    def preferred_method_name(method_id)
      method_name = method_id.to_s
      return nil unless where = Where.get(method_name)
      where[:aliases].each do |a|
        break if method_name.sub!(/#{a}(=?)$/, "#{where[:name]}\\1")
      end
      method_name
    end
    
    def matches_association(method_id, attribute, condition)
      @association_names.each do |association|
        test_attribute = attribute.dup
        if test_attribute.gsub!(/^#{association}_/, '') &&
          match = method_id.to_s.match("^(#{association})_(#{test_attribute})_(#{condition})=?$")
          return match
        end
      end
      nil
    end
    
    def matches_where_method(method_id)
      if match = method_id.to_s.match(/^add_(.*)_where$/)
        condition = match.captures.first
        Where.get(condition) ? match : nil
      end
    end
    
    def assign_attributes(opts)
      opts.each_pair do |k, v|
        self.send("#{k}=", v)
      end
    end

    def type_for(attribute)
      column = self.column(attribute)
      column.type if column
    end
    
    def class_for(attribute)
      column = self.column(attribute)
      column.klass if column
    end
    
    def association_type_for(association, attribute)
      column = self.association_column(association, attribute)
      column.type if column
    end
    
    def association_class_for(association, attribute)
      column = self.association_column(association, attribute)
      column.klass if column
    end
  end
end