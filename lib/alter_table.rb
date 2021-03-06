require 'active_support'

module AlterTable
  def alter_table(name, &block)
    TableAlterer.new(name, adapter_for_alter_table, &block)
  end

  class TableAlterer # :nodoc:
    module ColumnAlterations # :nodoc:
      def self.included(base)
        base.delegate :add_column_options!, :quote_column_name, :type_to_sql, :to => :adapter
      end

      def add_column(column_name, type, options = {})
        add_column_sql = "ADD COLUMN #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
        add_column_options!(add_column_sql, options)
        push_alterations(add_column_sql)
      end

      def remove_column(*column_names)
        push_alterations(*column_names.flatten.map { |column_name| "DROP COLUMN #{quote_column_name(column_name)}" })
      end

      def rename_column(original_name, new_name, type, options = {})
        rename_column_sql = "CHANGE COLUMN #{quote_column_name(original_name)} #{quote_column_name(new_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
        add_column_options!(rename_column_sql, options)
        push_alterations(rename_column_sql)
      end
    end

    module IndexAlterations # :nodoc:
      def self.included(base)
        base.delegate :index_name, :index_exists?, :quoted_columns_for_index, :quote_column_name, :index_name_length, :to => :adapter
      end

      def add_index(column_name, options = {})
        column_names           = Array(column_name)
        index_type, index_name = options, index_name(table, :column => column_names)
        if Hash === options
          index_name = options[:name] || index_name
          index_type = options[:unique] ? "UNIQUE" : ""
        end

        if index_name.length > index_name_length
          logger.warn("Index name '#{index_name}' on table '#{table}' is too long; the limit is #{index_name_length} characters. Skipping.")
          return
        end
        if index_exists?(table, index_name, false)
          logger.warn("Index name '#{index_name}' on table '#{table}' already exists. Skipping.")
          return
        end
        quoted_column_names = quoted_columns_for_index(column_names, options).join(", ")

        push_alterations("ADD #{index_type} INDEX #{quote_column_name(index_name)} (#{quoted_column_names})")
      end

      def remove_index(options = {})
        index_name = index_name(table, options)
        unless index_exists?(table, index_name, true)
          logger.warn("Index name '#{index_name}' on table '#{table}' does not exist. Skipping.")
          return
        end

        push_alterations("DROP INDEX #{quote_column_name(index_name)}")
      end
    end

    module Alterations # :nodoc:
      def self.included(base)
        base.delegate :quote_table_name, :to => :adapter
      end

      def execute
        raise StandardError, "No table alterations specified" if @alterations.blank?
        adapter.execute("ALTER TABLE #{quote_table_name(table)} #{@alterations.join(", ")}")
      end

      def push_alterations(*alterations)
        @alterations ||= []
        @alterations.concat(alterations)
      end
      private :push_alterations
    end

    def initialize(table, adapter, &block)
      @table, @adapter = table, adapter
      instance_eval(&block)
      execute
    end

    include ColumnAlterations
    include IndexAlterations
    include Alterations

    attr_reader :table, :adapter
    private :table, :adapter

    def logger
      adapter.instance_variable_get(:@logger)
    end
    private :logger
  end

  module CloneTable
    def clone_table(name, options = {}, &block)
      source, destination = name, options[:to]
      source, destination = options[:from], name if destination.nil?
      raise 'Specify source & destination table names' if source.nil? or destination.nil?
      TableCloner.new(source, destination, adapter_for_alter_table, &block)
    end

    class TableCloner
      def initialize(source, destination, adapter, &block)
        @source, @destination, @adapter = source, destination, adapter
        execute
        alter_table(@destination, &block) if block_given?
      end

      include AlterTable

      attr_reader :source, :destination, :adapter
      private :source, :destination, :adapter
      alias_method(:adapter_for_alter_table, :adapter)
      delegate :quote_table_name, :to => :adapter

      def execute
        adapter.execute("CREATE TABLE #{quote_table_name(destination)} LIKE #{quote_table_name(source)}")
      end
    end
  end
end

require 'active_record'

module ActiveRecord # :nodoc:
  module ConnectionAdapters # :nodoc:
    class AbstractAdapter # :nodoc:
      include AlterTable
      include AlterTable::CloneTable

      def adapter_for_alter_table
        self
      end
      private :adapter_for_alter_table
    end
  end
end
