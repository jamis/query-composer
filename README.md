# Query::Composer

Simple SQL queries are, well, simple. But when you start needing to deal with nested subqueries, and especially when those nested subqueries themselves require nested subqueries...things start getting difficult to manage.

`Query::Composer` was extracted from a real application, where reporting queries were dynamically generated and typically exceeded 50KB of text for the query alone!

This library allows you to specify each component of query independently, as well as allowing you to indicate which other components each component depends on. The composer will then build the correct query from those components, on demand.

## Features

* Define your queries in terms of components, each of which is more easily tested and debugged
* A dependency-resolution system for determining the proper ordering of query subcomponents within a complex query
* A simple class (`Query::Base`) for more conveniently defining queries using Arel
* The ability to generate the same query using either derived tables (nested subqueries), or CTEs (Common Table Expressions)


## Usage

First, instantiate a composer object:

```ruby
require 'query/composer'

composer = Query::Composer.new
```

Then, declare the components of your query with the `#use` method:

```ruby
composer.use(:patrons) { Patron.all }
```

Declare dependent components by providing parameters to the block that are named the same as the components that should be depended on:

```ruby
# `patrons` must exist as another component in the composer...
composer.use(:books) { |patrons| ... }
```

Component definitions must return an object that responds to either `#arel`, or `#to_sql`:

```ruby
# ActiveRecord scopes respond to #arel
composer.use(:patrons) { Patron.all }

require 'query/base'

# Arel objects and Query::Base (a thin wrapper around
# Arel::SelectManager) respond to #to_sql
composer.use(:books_by_patron) do |patrons|
  books = Book.arel_table
  lendings = Lending.arel_table

  Query::Base.new(books).
    project(patrons[:first_name], books[:name]).
    join(lendings).
      on(lendings[:book_id].eq(books[:id])).
    join(patrons).
      on(patrons[:id].eq(lendings[:patron_id]))
end
```

Generate the query by calling `#build` on the composer, and telling it which component will be the root of the query:

```ruby
# Builds the query using the books_by_patron component as the root.
query = composer.build(:books_by_patron)
# SELECT "patrons"."first_name", "books"."name"
# FROM "books"
# INNER JOIN "lendings"
# ON "lendings"."book_id" = "books"."id"
# INNER JOIN (
#   SELECT "patrons".* FROM "patrons"
# ) "patrons"
# ON "patrons"."id" = "lendings"."patron_id"

# Builds the query using the patrons component as the root
query = composer.build(:patrons)
# SELECT "patrons".* FROM "patrons"
```

Run the query by converting it to SQL and executing it:

```ruby
sql = query.to_sql

# using raw ActiveRecord connection
rows = ActiveRecord::Base.connection.execute(sql)

# using ActiveRecord models
rows = Book.find_by_sql(sql)
```


## Example

Let's use a library system as an example. (See this full example in `examples/library.rb`.) We'll imagine that there is some administrative interface where users can generate reports. One report in particular is used to show:

* All patrons from a specified set of libraries,
* Who have checked out books this month,
* From a specified set of topics,
* And compare that with the same period of the previous month.

We will assume that we have a data model consisting of libraries, topics, books, patrons, and lendings, where books belong to libraries and topics, and lendings relate patrons to books, and include the date the lending was created.

First, instantiate a composer object:

```ruby
require 'query/composer'
require 'query/base'

composer = Query::Composer.new
```

We'll assume we have some object that describes the parameters for the query, as given by the user:

```ruby
today = Date.today

config.current_period_from = today.beginning_of_month
config.current_period_to   = today
config.prior_period_from   = today.last_month.beginning_of_month
config.prior_period_to     = today.last_month

config.library_ids         = [ ... ]
config.topic_ids           = [ ... ]
```

Then, we tell the composer about the components of our query:

```ruby
# The set of libraries specified by the user
composer.use(:libraries_set) { Library.where(id: config.library_ids) }

# The set of topics specified by the user
composer.use(:topics_set) { Topic.where(id: config.topic_ids) }

# The set of patrons to consider (all of them, here)
composer.use(:patrons_set) { Patron.all }

# The set of books to consider (all those from the given libraries
# with the given topics)
composer.use(:books_set) do |libraries_set, topics_set|
  books = Book.arel_table

  Query::Base.new(books).
    project(books[:id]).
    join(libraries_set).
      on(books[:library_id].eq(libraries_set[:id])).
    join(topics_set).
      on(books[:topic_id].eq(topics_set[:id]))
end
```

Note the use of the parameters in the block for `books_set`. The names for the parameters are explicitly chosen here to match the names of other query components. `Query::Composer` uses these names to determine which components a component depends on--in this case, `books_set` depends on both `libraries_set` and `topics_set`.

We still need to tell the composer how to find the lendings. Because we'll need the same query with two different date spans (one for the "current" period, and one for the "prior" period), we'll create a helper method:

```ruby
# books_set -- the set of books to be considered
# from_date -- the beginning of the period to consider
# to_date -- the end of the period to consider
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
```

This lendings set will be all patron ids who borrowed any of the books in the given set, between the given dates, and will include how many books were borrowed by each patron during that period.

With that, we can now finish defining our query components:

```ruby
# Books in the "current" set
composer.use(:current_set) do |books_set|
  lendings_set(books_set,
    config.current_period_from,
    config.current_period_to)
end

composer.use(:prior_set) do |books_set|
  lendings_set(books_set,
    config.prior_period_from,
    config.prior_period_to)
end

# Joins the current_set and prior_set to the patrons_set
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
```

There--our query is defined. Now we just need to tell the composer to generate the SQL. Once we have the SQL, we can use it to query the database:

```ruby
sql = composer.build(:combined_set).to_sql

Patron.find_by_sql(sql).each do |patron|
  puts "#{patron.name} :: #{patron.current_total} :: #{patron.prior_total}"
end
```

The generated query, assuming a current month of Feb 2016, might look like this (formatted for readability):

```sql
SELECT a.*,
       e."total" AS current_total,
       f."total" AS prior_total
FROM (
  SELECT "patrons".*
  FROM "patrons"
) a
INNER JOIN (
  SELECT "lendings"."patron_id",
         COUNT("lendings"."patron_id") AS total
  FROM "lendings"
  INNER JOIN (
    SELECT "books"."id"
    FROM "books"
    INNER JOIN (
      SELECT "libraries".*
      FROM "libraries"
      WHERE "libraries"."id" IN (1, 2)
    ) b
    ON "books"."library_id" = b."id"
    INNER JOIN (
      SELECT "topics".*
      FROM "topics"
      WHERE "topics"."id" IN (1, 2, 3, 4)
    ) c
    ON "books"."topic_id" = c."id"
  ) d
  ON "lendings"."book_id" = d."id"
  WHERE "lendings"."created_at" BETWEEN '2016-02-01' AND '2016-02-15'
  GROUP BY "lendings"."patron_id"
) e
ON e."patron_id" = a."id"
LEFT OUTER JOIN (
  SELECT "lendings"."patron_id",
         COUNT("lendings"."patron_id") AS total
  FROM "lendings"
  INNER JOIN (
    SELECT "books"."id"
    FROM "books"
    INNER JOIN (
      SELECT "libraries".*
      FROM "libraries"
      WHERE "libraries"."id" IN (1, 2)
    ) b
    ON "books"."library_id" = b."id"
    INNER JOIN (
      SELECT "topics".*
      FROM "topics"
      WHERE "topics"."id" IN (1, 2, 3, 4)
    ) c
    ON "books"."topic_id" = c."id"
  ) d
  ON "lendings"."book_id" = d."id"
  WHERE "lendings"."created_at" BETWEEN '2016-01-01' AND '2016-01-15'
  GROUP BY "lendings"."patron_id"
) f
ON f."patron_id" = a."id"
```

For databases that support Common Table Expressions (CTE, or "with" queries), you can pass `use_cte: true` to the `composer#build` method to have the composer generate a CTE query instead. (NOTE that CTE queries can be very inefficient in some DBMS's, like PostgreSQL!)

```ruby
sql = composer.build(:combined_set, use_cte: true)
```

The CTE query looks like this:

```sql
WITH
  "a" AS (
    SELECT "patrons".* FROM "patrons"),
  "b" AS (
    SELECT "libraries".*
    FROM "libraries"
    WHERE "libraries"."id" IN (1, 2)),
  "c" AS (
    SELECT "topics".*
    FROM "topics"
    WHERE "topics"."id" IN (1, 2, 3, 4)),
  "d" AS (
    SELECT "books"."id"
    FROM "books"
    INNER JOIN "b"
      ON "books"."library_id" = "b"."id"
    INNER JOIN "c"
      ON "books"."topic_id" = "c"."id"),
  "e" AS (
    SELECT "lendings"."patron_id",
           COUNT("lendings"."patron_id") AS total
    FROM "lendings"
    INNER JOIN "d"
      ON "lendings"."book_id" = "d"."id"
    WHERE "lendings"."created_at" BETWEEN '2016-02-01' AND '2016-02-15'
    GROUP BY "lendings"."patron_id"),
  "f" AS (
    SELECT "lendings"."patron_id",
           COUNT("lendings"."patron_id") AS total
    FROM "lendings"
    INNER JOIN "d" ON "lendings"."book_id" = "d"."id"
    WHERE "lendings"."created_at" BETWEEN '2016-01-01' AND '2016-01-15'
    GROUP BY "lendings"."patron_id")
SELECT "a".*,
       "e"."total" AS current_total,
       "f"."total" AS prior_total
FROM "a"
INNER JOIN "e"
ON "e"."patron_id" = "a"."id"
LEFT OUTER JOIN "f"
ON "f"."patron_id" = "a"."id"
```

Also, to make it easier to debug queries, you can also pass `use_aliases: false` to `composer#build` in order to make the composer use the full component names, instead of shorter aliases. 

```ruby
sql = composer.build(:combined_set, use_aliases: false)
```

The resulting query:

```sql
SELECT patrons_set.*,
       current_set."total" AS current_total,
       prior_set."total" AS prior_total
FROM (
  SELECT "patrons".*
  FROM "patrons"
) patrons_set
INNER JOIN (
  SELECT "lendings"."patron_id",
         COUNT("lendings"."patron_id") AS total
  FROM "lendings"
  INNER JOIN (
    SELECT "books"."id"
    FROM "books"
    INNER JOIN (
      SELECT "libraries".*
      FROM "libraries"
      WHERE "libraries"."id" IN (1, 2)
    ) libraries_set
    ON "books"."library_id" = libraries_set."id"
    INNER JOIN (
      SELECT "topics".*
      FROM "topics"
      WHERE "topics"."id" IN (1, 2, 3, 4)
    ) topics_set
    ON "books"."topic_id" = topics_set."id"
  ) books_set
  ON "lendings"."book_id" = books_set."id"
  WHERE "lendings"."created_at" BETWEEN '2016-02-01' AND '2016-02-15'
  GROUP BY "lendings"."patron_id"
) current_set
ON current_set."patron_id" = patrons_set."id"
LEFT OUTER JOIN (
  SELECT "lendings"."patron_id",
         COUNT("lendings"."patron_id") AS total
  FROM "lendings"
  INNER JOIN (
    SELECT "books"."id"
    FROM "books"
    INNER JOIN (
      SELECT "libraries".*
      FROM "libraries"
      WHERE "libraries"."id" IN (1, 2)
    ) libraries_set
    ON "books"."library_id" = libraries_set."id"
    INNER JOIN (
      SELECT "topics".*
      FROM "topics"
      WHERE "topics"."id" IN (1, 2, 3, 4)
    ) topics_set
    ON "books"."topic_id" = topics_set."id"
  ) books_set
  ON "lendings"."book_id" = books_set."id"
  WHERE "lendings"."created_at" BETWEEN '2016-01-01' AND '2016-01-15'
  GROUP BY "lendings"."patron_id"
) prior_set
ON prior_set."patron_id" = patrons_set."id"
```

## License

`Query::Composer` is distributed under the MIT license. (See the LICENSE file for more information.)


## Author

`Query::Composer` is written and maintained by Jamis Buck <jamis@jamisbuck.org>. Many thanks to [T2 Modus](http://t2modus.com/) for permitting this code to be released as open source!
