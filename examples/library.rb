# A simple example that demonstrates the use of Query::Composer in a
# library reporting system. Given a data model that includes sets of
# libraries, topics, books, and patrons, and permits books to be lended
# from a library to a patron on a given date, this script builds and
# executes a query that shows how many books from a given set of topics
# and libraries each patron borrowed during a given period of time, and
# compares it to the corresponding period of the previous month.

require 'active_record'
require 'query/composer'
require 'query/base'

# connect to the DB
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# generate the schema
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :libraries do |t|
    t.string :name
  end

  create_table :topics do |t|
    t.string :name
  end

  create_table :patrons do |t|
    t.string :name
  end

  create_table :books do |t|
    t.string :name
    t.integer :library_id
    t.integer :topic_id
  end

  create_table :lendings do |t|
    t.integer :book_id
    t.integer :patron_id
    t.date    :created_at
  end
end

# populate the database

ActiveRecord::Base.connection.execute <<-SQL
  INSERT INTO libraries (id, name)
    VALUES (1, 'Gotham'),
           (2, 'Hogwarts')
SQL

ActiveRecord::Base.connection.execute <<-SQL
  INSERT INTO topics (id, name)
    VALUES (1, 'Warts'),
           (2, 'Seaweed'),
           (3, 'Dryer Lint'),
           (4, 'Sitcoms')
SQL

ActiveRecord::Base.connection.execute <<-SQL
  INSERT INTO patrons (id, name)
    VALUES (1, 'Harry'),
           (2, 'Mary'),
           (3, 'Larry'),
           (4, 'Carry'),
           (5, 'Terry'),
           (6, 'Cheri')
SQL

ActiveRecord::Base.connection.execute <<-SQL
  INSERT INTO books (id, name, library_id, topic_id)
    VALUES (1, 'Odd Growths', 1, 1),
           (2, 'Nose Accessories', 2, 1),
           (3, 'Health Foods', 1, 2),
           (4, 'Green', 1, 2),
           (5, 'Slimy Things', 1, 2),
           (6, 'Household Chores', 2, 3),
           (7, 'Starting Fires', 2, 3),
           (8, 'Laughter', 1, 4),
           (9, 'Funny People', 1, 4),
           (10, 'Silliness', 2, 4)
SQL

ActiveRecord::Base.connection.execute <<-SQL
  INSERT INTO lendings (book_id, patron_id, created_at)
    VALUES (1, 1, '2016-01-01'),
           (2, 2, '2016-01-04'),
           (3, 3, '2016-01-05'),
           (4, 4, '2016-01-06'),
           (5, 4, '2016-01-08'),
           (6, 4, '2016-01-08'),
           (7, 5, '2016-01-11'),
           (8, 6, '2016-01-12'),
           (9, 6, '2016-01-14'),
           (10, 6, '2016-01-15'),
           (1, 6, '2016-02-01'),
           (2, 6, '2016-02-04'),
           (3, 5, '2016-02-05'),
           (4, 5, '2016-02-06'),
           (5, 4, '2016-02-08'),
           (6, 3, '2016-02-08'),
           (7, 3, '2016-02-11'),
           (8, 2, '2016-02-12'),
           (9, 2, '2016-02-14'),
           (10, 1, '2016-02-15')
SQL

# define the models

class Library < ActiveRecord::Base
  has_many :books
end

class Topic < ActiveRecord::Base
  has_many :books
end

class Patron < ActiveRecord::Base
  has_many :lendings
  has_many :books, through: :lendings
end

class Book < ActiveRecord::Base
  belongs_to :library
  belongs_to :topic
  has_many :lendings
  has_many :patrons, through: :lendings
end

class Lending < ActiveRecord::Base
  belongs_to :patron
  belongs_to :book
end

# Construct the reporting query

composer = Query::Composer.new

composer.use(:libraries_set) { Library.where(id: [ 1, 2 ]) }
composer.use(:topics_set) { Topic.where(id: [ 1, 2, 3, 4 ]) }
composer.use(:patrons_set) { Patron.all }

composer.use(:books_set) do |libraries_set, topics_set|
  books = Book.arel_table

  Query::Base.new(books).
    project(books[:id]).
    join(libraries_set).
      on(books[:library_id].eq(libraries_set[:id])).
    join(topics_set).
      on(books[:topic_id].eq(topics_set[:id]))
end

composer.use(:current_set) do |books_set|
  lendings_set(books_set, '2016-02-01', '2016-02-15')
end

composer.use(:prior_set) do |books_set|
  lendings_set(books_set, '2016-01-01', '2016-01-15')
end

composer.use(:combined_set) do |patrons_set, current_set, prior_set|
  Query::Base.new(patrons_set).
    project(patrons_set[Arel.star],
            current_set[:total].as("current_total"),
            prior_set[:total].as("prior_total")).
    join(current_set).
      on(current_set[:patron_id].eq(patrons_set[:id])).
    join(prior_set, Arel::Nodes::OuterJoin).
      on(prior_set[:patron_id].eq(patrons_set[:id]))
end

def lendings_set(books_set, from_date, to_date)
  lendings = Lending.arel_table

  patron_id = lendings[:patron_id]
  count = patron_id.count.as("total")

  Query::Base.new(lendings).
    project(patron_id, count).
    join(books_set).
      on(lendings[:book_id].eq(books_set[:id])).
    where(lendings[:created_at].between(from_date..to_date)).
    group(patron_id)
end

sql = composer.build(:combined_set).to_sql
puts "---- SQL ----"
puts sql

puts
puts "%-6s | %3s | %5s" % %w(Patron Now Prior)
puts "%-6s-+-%3s-+-%5s-" % ["-"*6, "-"*3, "-"*5]

Patron.find_by_sql(sql).each do |patron|
  puts "%-6s | %3d | %5d" % [ patron.name, patron.current_total, patron.prior_total||0]
end
