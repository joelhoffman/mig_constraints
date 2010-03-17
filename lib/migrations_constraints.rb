# MigrationsConstraints
module ActiveRecord
  
  module ConnectionAdapters
    
    class ConstraintDefinition < Struct.new(:base, :type, :table, :column)
      attr_accessor :options
      
      def initialize(base, type, table, column, options = {})
        super(base, type, table, column)
        @options = options
      end
      
      def [](name)
        @options[name]
      end
      
      def to_sql
        base.construct_constraint_clause(type, table.name, [column.name], options)
      end
      
    end
    
    class TableDefinition
      attr_accessor :name
      attr_reader :constraints
      
      def initialize(base, name)
        @columns = []
        @constraints = []
        @base = base
        @name = name
      end
      
      def column(name, type, options = {})
        # copied directly from ActiveRecord 2.3.5
        column = self[name] || ColumnDefinition.new(@base, name, type)
        if options[:limit]
          column.limit = options[:limit]
        elsif native[type.to_sym].is_a?(Hash)
          column.limit = native[type.to_sym][:limit]
        end
        column.precision = options[:precision]
        column.scale = options[:scale]
        column.default = options[:default]
        column.null = options[:null]
        @columns << column unless @columns.include? column
        
        # Add constraints to this column as specified
        constraint :unique, column, constraint_options(:unique, options)          if options[:unique]
        constraint :foreign_key, column, constraint_options(:references, options) if options[:references]
        constraint :check, column, constraint_options(:check, options)            if options[:check]
        self
      end
      
      def references(table_name, options = {})
        column_name = (ActiveRecord::Base.pluralize_table_names ? table_name.to_s.singularize : table_name) + '_id'
        column column_name, :integer, {:null => false, :references => table_name}.merge(options)
      end

      def constraint(type, column, options = {})
        if constraint = find_constraint_by_name(options[:name])     
          constraint.options.merge(options)
        else
          column = self[column] unless column.is_a?(ColumnDefinition)
          @constraints << ConstraintDefinition.new(@base, type, self, column, options) if column
        end
        
        self
      end

      def constraint_options (type, options = {})
        # added to support named foreign key constraints if default name is too long
        new_options = {}
        new_options[:name] = options[:name] if options[:name]
        case type
        when :references
          [type, :cascade, :deferrable, :initially].each do |t|
            new_options[t] = options[t] if options[t]
          end
        when :check
          new_options[type] = options[type] if options[type]
        end
        new_options
      end
      
      def to_sql_with_constraints
        ([to_sql_without_constraints] + @constraints.map(&:to_sql)) * ', '
      end
      
      alias_method_chain :to_sql, :constraints

      protected
      
      def find_constraint_by_name(name)
        @constraints.find {|constraint| constraint[:name].to_s == name.to_s } if name
      end
    end
    
    class AbstractAdapter
      
      CONSTRAINT_SUFFIX_MAP = {:unique => 'uq', :foreign_key => 'fkey', :check => 'check'}
      
      def default_constraint_name(table_name, type, parts)
        parts = [parts] unless parts.is_a?(Array)
        "#{table_name}_#{parts.join('_')}_#{CONSTRAINT_SUFFIX_MAP[type]}"
      end
      
      def construct_constraint_clause(type, table_name, column_or_columns, options = {})
        columns = column_or_columns.is_a?(Array) ? column_or_columns : [column_or_columns]
        quoted_column_names = columns.map {|cn| quote_column_name(cn)}.join(', ')
        
        name = options[:name] || default_constraint_name(table_name, type, columns)
        case type
        when :unique
          definition = "UNIQUE (#{quoted_column_names})"
        when :foreign_key
          references = options[:references]
          if references.is_a?(Hash)
            definition = "FOREIGN KEY (#{quoted_column_names}) REFERENCES #{references[:table]} (#{quote_column_name(references[:column])})"
          else
            definition = "FOREIGN KEY (#{quoted_column_names}) REFERENCES #{references} (#{quote_column_name('id')})"
          end

          if options[:cascade]
            definition += ' ON DELETE CASCADE'
          end

          if options[:deferrable]
            definition += ' DEFERRABLE'
            if options[:initially]
              definition += ' INITIALLY ' + options[:initially]
            end
          end
        when :check
          if check = options[:check]
            definition = "CHECK (#{quote_column_name(columns[0])} #{check})"
          end
        else
          raise "DefaultAdapter: Unknown constraint type #{type}"
        end
        
        "CONSTRAINT #{quote_column_name(name)} #{definition}" if definition
      end
      
    end
    
    module SchemaStatements
      
      def create_table(name, options = {})
        table_definition = TableDefinition.new(self, name)
        table_definition.primary_key(options[:primary_key] || "id") unless options[:id] == false
        
        yield table_definition
        
        if options[:force]
          drop_table(name, options) rescue nil
        end
        
        create_sql = "CREATE#{' TEMPORARY' if options[:temporary]} TABLE "
        create_sql << "#{name} ("
        create_sql << table_definition.to_sql
        create_sql << ") #{options[:options]}"
        execute create_sql
      end
      
      def add_constraint(table_name, options = {})
        constraint_clause = case
        when columns = options[:unique]
          construct_constraint_clause(:unique, table_name, columns, options)
        when columns = options[:foreign_key]
          construct_constraint_clause(:foreign_key, table_name, columns, options)
        when check = options[:check]
          check = "(#{check})" unless check =~ /\A\(.+\)\Z/
          "CONSTRAINT #{quote_column_name(options[:name])} CHECK #{check}" if options[:name]
        end
        
        if constraint_clause
          execute "ALTER TABLE #{table_name} ADD #{constraint_clause}"
        else
          raise "Don't know how to create constraint for #{options.inspect}!"
        end
      end
      
      def drop_constraint(table_name, options = {})
        name = options[:name] || case
        when options[:unique]
          default_constraint_name(table_name, :unique, options[:unique])
          execute "ALTER TABLE #{table_name} DROP CONSTRAINT #{name}"
        when options[:foreign_key]
          default_constraint_name(table_name, :foreign_key, options[:foreign_key])
          execute "ALTER TABLE #{table_name} DROP FOREIGN KEY #{name}"
        when options[:check]
          default_constraint_name(table_name, :check, options[:check])
          execute "ALTER TABLE #{table_name} DROP CONSTRAINT #{name}"
        else
          raise "Unknown constraint type for #{options.inspect}!"
        end
      end
    end
    
  end
  
end
