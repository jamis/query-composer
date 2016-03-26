require 'minitest/autorun'
require 'active_record'

require 'query/composer'
require 'query/base'
require 'query/wrapper'

ActiveRecord::Base.logger = Logger.new(File.open("test.log", "w"))

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :people do |t|
    t.string :first_name
    t.integer :company_id
  end

  create_table :companies do |t|
    t.string :name
  end
end

ActiveRecord::Base.connection.execute <<-SQL
  INSERT INTO people (id, first_name, company_id)
    VALUES (1, 'Harry', 1),
           (2, 'Margaret', 1),
           (3, 'Jesse', 2);
SQL

ActiveRecord::Base.connection.execute <<-SQL
  INSERT INTO companies (id, name)
    VALUES (1, 'Big Company'),
           (2, 'Little Company');
SQL

class Person < ActiveRecord::Base
  belongs_to :company
end

class Company < ActiveRecord::Base
  has_many :people
end
