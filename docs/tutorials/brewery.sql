-- docs/tutorials/brewery.sql
-- The Bier tutorial database: a brewery catalog.
-- Load with:  psql -d bier_tutorial -f docs/tutorials/brewery.sql

-- ---------------------------------------------------------------------------
-- Roles (PostgREST-style): `authenticator` connects and can switch into the
-- anonymous or member role. Change the password before using anywhere real.
-- ---------------------------------------------------------------------------
create role authenticator noinherit login password 'mysecretpassword';
create role web_anon nologin;
create role brewery_member nologin;
grant web_anon to authenticator;
grant brewery_member to authenticator;

create schema api;
grant usage on schema api to web_anon, brewery_member;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table api.styles (
  id          serial primary key,
  name        text not null unique,
  description text
);

create table api.breweries (
  id           serial primary key,
  name         text not null,
  city         text,
  country      text,
  founded_year int,
  latitude     numeric(9,6),
  longitude    numeric(9,6)
);

create table api.beers (
  id          serial primary key,
  brewery_id  int not null references api.breweries(id),
  style_id    int references api.styles(id),
  name        text not null,
  abv         numeric(4,2),
  ibu         int,
  description text
);

create table api.taprooms (
  id         serial primary key,
  brewery_id int not null references api.breweries(id),
  name       text not null,
  address    text,
  city       text
);

create table api.check_ins (
  id         serial primary key,
  beer_id    int not null references api.beers(id),
  drinker    text not null,
  rating     int not null check (rating between 1 and 5),
  comment    text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Functions (RPC)
-- ---------------------------------------------------------------------------
create function api.search_beers(term text) returns setof api.beers
  language sql stable as $$
    select * from api.beers
    where name ilike '%' || term || '%'
       or coalesce(description, '') ilike '%' || term || '%';
  $$;

create function api.top_rated_beers(min_rating int default 4)
  returns table(beer_id int, name text, avg_rating numeric, check_in_count bigint)
  language sql stable as $$
    select b.id, b.name, round(avg(c.rating), 2), count(c.id)
    from api.beers b
    join api.check_ins c on c.beer_id = b.id
    group by b.id, b.name
    having avg(c.rating) >= min_rating
    order by avg(c.rating) desc;
  $$;

-- ---------------------------------------------------------------------------
-- Grants: web_anon reads the catalog; brewery_member also posts check-ins.
-- ---------------------------------------------------------------------------
grant select on api.styles, api.breweries, api.beers, api.taprooms, api.check_ins to web_anon;
grant execute on function api.search_beers(text), api.top_rated_beers(int) to web_anon;

grant select on api.styles, api.breweries, api.beers, api.taprooms, api.check_ins to brewery_member;
grant insert on api.check_ins to brewery_member;
grant usage on sequence api.check_ins_id_seq to brewery_member;
grant execute on function api.search_beers(text), api.top_rated_beers(int) to brewery_member;

-- ---------------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------------
insert into api.styles (name, description) values
  ('IPA', 'India Pale Ale — hop-forward and bitter'),
  ('Stout', 'Dark, roasted, full-bodied'),
  ('Pilsner', 'Crisp pale lager'),
  ('Saison', 'Fruity, spicy farmhouse ale'),
  ('Hazy IPA', 'Juicy, cloudy New England IPA');

insert into api.breweries (name, city, country, founded_year, latitude, longitude) values
  ('Reunion Brewing', 'Portland', 'USA', 2016, 45.512230, -122.658722),
  ('Kernel Brewery', 'London', 'UK', 2009, 51.494400, -0.070300),
  ('Cloudwater', 'Manchester', 'UK', 2014, 53.474800, -2.238300),
  ('Tanque Verde', 'Tucson', 'USA', 2019, 32.221700, -110.926500);

insert into api.beers (brewery_id, style_id, name, abv, ibu, description) values
  (1, 1, 'Trail Crest IPA', 6.80, 65, 'Piney West Coast IPA'),
  (1, 5, 'Fog Line', 6.20, 40, 'Hazy and juicy'),
  (2, 3, 'Table Pils', 4.80, 30, 'Delicate and dry'),
  (2, 2, 'Export Stout', 7.50, 55, 'Rich roasted stout'),
  (3, 5, 'DIPA v12', 8.50, 70, 'Big hazy double IPA'),
  (4, 4, 'Desert Saison', 5.90, 25, 'Peppery farmhouse ale');

insert into api.taprooms (brewery_id, name, address, city) values
  (1, 'Reunion Taproom', '123 SE Ash St', 'Portland'),
  (3, 'Cloudwater Barrel Store', 'Unit 7-8 Sheffield St', 'Manchester');

insert into api.check_ins (beer_id, drinker, rating, comment) values
  (1, 'sam',  5, 'Loved the pine'),
  (1, 'alex', 4, 'Solid IPA'),
  (4, 'sam',  5, 'Best stout in town'),
  (5, 'jo',   4, 'Juicy'),
  (2, 'alex', 3, 'Fine');
