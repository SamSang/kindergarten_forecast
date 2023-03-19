/*
PostGIS pipeline to create intersections of census and catchment data
*/


-- union all the elementary catchments by year

drop table if exists  sdp.catchments_all_years;

create table if not exists sdp.catchments_all_years as
select
	2016 as catchment_year,
	es_id,
	es_name,
	es_short,
	wkb_geometry
from
	sdp.catchment_es_2016

union all

select
	2017 as catchment_year,
	es_id,
	es_name,
	es_short,
	wkb_geometry
from
	sdp.catchment_es_2017

union all

select
	2018 as catchment_year,
	es_id,
	es_name,
	es_short,
	wkb_geometry
from
	sdp.catchment_es_2018

union all

select
	2019 as catchment_year,
	es_id,
	es_name,
	es_short,
	wkb_geometry
from
	sdp.catchment_es_2019;


-- get intersections for all years

drop table if exists public.catchment_overlap;

create table if not exists public.catchment_overlap as
	select
		catch.catchment_year as catchment_year,
		catch.es_id,
		catch.es_short,
		tract.year as census_year,
		tract.geoid,
		tract.tractce,
		st_area(st_intersection(tract.wkb_geometry, catch.wkb_geometry)) as overlap_area, -- area of the intersection
		st_area(st_intersection(tract.wkb_geometry, catch.wkb_geometry)) / st_area(tract.wkb_geometry) as overlap_ratio, -- percent of the intersection in the catchment
		st_intersection(tract.wkb_geometry, catch.wkb_geometry) as overlap
	from
		census.tract
		inner join
			sdp.catchments_all_years catch
			on
				-- round catchments to last 10 years
				-- 5 year lag between birth and enrollment eligibiltiy
				round(catch.catchment_year - 5, -1) = tract.year
	where
		st_intersects(tract.wkb_geometry, catch.wkb_geometry);


-- match births to tracts

-- births all years

drop table if exists census.births_all_years;

create table if not exists census.births_all_years as

	select 
		2011 as "year",
		"index",
		census_tract,
		"all"
	from census.births_2011

	union all

	select 
		2012 as "year",
		"index",
		census_tract,
		"all"
	 from census.births_2012

	union all

	select 
		2013 as "year",
		"index",
		census_tract,
		"all"
	from census.births_2013

	union all

	select 
		2014 as "year",
		"index",
		census_tract,
		"all"
	from census.births_2014;


-- sum births by catchment

drop table if exists census.births_by_catchment;

create table census.births_by_catchment as
with overlap as (
	select
		overlap.census_year,
		overlap.catchment_year as catchment_year,
		--tract.name,
		overlap.tractce as tractce,
		overlap.es_id,
		overlap.es_short,
		births.all as births,
		overlap.overlap_ratio,
		births.all * overlap.overlap_ratio as births_weighted
	from
		census.births_all_years births
	inner join
		public.catchment_overlap overlap
		on
			overlap.tractce = lpad(cast(births.census_tract as text), 6, '0')
		and
			overlap.catchment_year = births.year + 5
)
select
	census_year,
	catchment_year,
	es_id,
	es_short,
	sum(births_weighted) as total_births
from
	overlap
group by
	census_year,
	catchment_year,
	es_id,
	es_short;


-- get kingergarten enrollment

-- union all the years of enrollment together

drop table if exists sdp.schools_demog_all_years;

create table sdp.schools_demog_all_years as
select
	school_year,
	cast(school_id as text) as school_id,
	school_name,
	learning_network,
	grade,
	total_enrolled
from sdp.schools_demog_2016_2017 -- remove s from the ethnicity data

union all

select 
	school_year,
	cast(school_id as text) as school_id,
	school_name,
	learning_network,
	grade,
	cast(total_enrolled as text) as total_enrolled
from sdp.schools_demog_2017_2018

union all

select
	school_year,
	src_school_id as school_id,
	school_name,
	learning_network,
	grade_level as grade,
	cast(student_enrollment as text) as total_enrolled
from sdp.schools_demog_2018_2019

union all

select
	schoolyear as school_year,
	srcschoolid as school_id,
	schoolname as school_name,
	learningnetwork as learning_network,
	gradelevel as grade,
	cast(studentenrollment as text) as total_enrolled
from sdp.schools_demog_2019_2020;

select count(*), school_year
from sdp.schools_demog_all_years
group by school_year;

select *
from
sdp.schools_demog_all_years
where school_name like '%Lea%'
and grade = '0'
;


-- join enrollment and births to see the ratio

drop table if exists public.births_to_enrollment;

create table if not exists public.births_to_enrollment as
with kindergarten as (
	select
		school_year,
		cast(substring(school_year, 1, 4) as integer) as catchment_year,
		rpad(school_id, 4, '0') as es_id,
		school_name,
		--learning_network,
		cast(total_enrolled as integer) as total_enrolled
	from sdp.schools_demog_all_years
	where grade in ('0', '00' )
	and lower(learning_network) like '%network%' -- (should) filter out charter schools
	--and school_id in( '134' , '1340')
)
select
	births.census_year,
	births.catchment_year,
	births.es_id,
	births.es_short,
	births.total_births,
	kindergarten.total_enrolled,
	kindergarten.total_enrolled / births.total_births as ratio
from
	census.births_by_catchment births
inner join
	kindergarten
	on
		births.es_id = kindergarten.es_id
	and
		kindergarten.catchment_year = births.catchment_year
;