/*
PostGIS pipeline to create intersections of census and catchment data
*/


-- create school locations as points

drop table if exists sdp.school_location;

create table sdp.school_location as
	select
		school_year,
		cast(substring(school_year, 1, 4) as integer) as start_year,
		ulcs_code,
		publication_name as school_name,
		school_region,
		current_grade_span_served,
		lower(governance) as governance,
		gps_location,
		cast(substring(gps_location, position(',' in gps_location) + 1) as float) as x,
		cast(substring(gps_location, 0, position(',' in gps_location)) as float) as y,
		-- Note the sequence:
		-- 1 Create a point using lat/long as float in 4326 coordinate system
		-- 2 reproject the 4326 points to 2272 points using ST_Transform
		--   simply setting the srid doesn't do this
		st_transform(
			st_point(
				cast(substring(gps_location, position(',' in gps_location) + 1) as float),
				cast(substring(gps_location, 0, position(',' in gps_location)) as float),
				4326),
			2272) as geo_id
	from sdp.school
	where gps_location is not null
	and (year_closed = 'open' or year_closed is null);
	


-- build view to restrict us to district schools

drop table if exists sdp.district_school;

create table sdp.district_school as
	with catchment as (
		select
			catchment_year,
			es_id,
			st_area(wkb_geometry) * 0.00002295686400367 as area_acre -- acres
		from sdp.catchments_all_years
	)
	select
		school_year,
		cast(substring(school_year, 1, 4) as integer) as start_year,
		ulcs_code,
		publication_name as school_name,
		school_region,
		area_acre
	from sdp.school
	left join
		catchment
		on
			catchment_year = cast(substring(school_year, 1, 4) as integer)
		and
			es_id = cast(ulcs_code as character varying)
	where school_year in ('2016-2017', '2017-2018', '2018-2019', '2019-2020')
	and upper(admission_type) = 'NEIGHBORHOOD'
	and upper(governance) = 'DISTRICT'
	and current_grade_span_served like '%00%'
	and (year_closed = 'open' or year_closed is null);


-- Compute tenure of the principal
drop table if exists sdp.school_tenure;

create table sdp.school_tenure as
	with leader as (
		select
			school_year,
			ulcs_code,
			publication_name,
			lower(replace(replace(replace(replace(school_leader_name, 'Ms. ', ''), 'Mr. ', ''), 'Mrs. ', ''), 'Dr. ', '')) as school_leader_name
		from sdp.school
		where (year_closed = 'open' or year_closed is null)
	),
	leader_logic as (
		select
			school_year,
			ulcs_code,
			publication_name,
			school_leader_name,
			lag(school_leader_name, 1, null) over (partition by ulcs_code order by school_year asc) as school_leader_name_prev,
			case
				when school_leader_name = lag(school_leader_name, 1, null) over (partition by ulcs_code order by school_year asc) then 1
				else 0
			end as school_leader_name_equal
		from
			leader
	)
	select
		school_year,
		cast(substring(school_year, 1, 4) as int) as catchment_year,
		cast(ulcs_code as character varying) as es_id,
		publication_name,
		school_leader_name,
	-- 	lag(school_leader_name, 1, null) over (partition by ulcs_code order by school_year asc) as school_leader_name_prev,
	-- 	case
	-- 		when school_leader_name = lag(school_leader_name, 1, null) over (partition by ulcs_code order by school_year asc) then 1
	-- 		else 0
	-- 	end as school_leader_name_equal,
		sum(school_leader_name_equal) over (
			partition by ulcs_code, school_leader_name
			order by school_year asc
		) + 1 as cumulative_tenure
	from
		leader_logic;


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


-- get intersections of tracts for all years

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


-- get intersections of block groups for all years

drop table if exists public.block_group_overlap;

create table public.block_group_overlap as
	select
		catch.catchment_year as catchment_year,
		catch.es_id,
		catch.es_short,
		block_group.year as census_year,
		block_group.geoid,
		block_group.tractce,
		block_group.blkgrpce,
		st_area(st_intersection(block_group.wkb_geometry, catch.wkb_geometry)) as overlap_area, -- area of the intersection
		st_area(st_intersection(block_group.wkb_geometry, catch.wkb_geometry)) / st_area(block_group.wkb_geometry) as overlap_ratio, -- percent of the intersection in the catchment
		st_intersection(block_group.wkb_geometry, catch.wkb_geometry) as overlap
	from
		census.block_group
		inner join
			sdp.catchments_all_years catch
			on
				-- round catchments to last 10 years
				-- 5 year lag between birth and enrollment eligibiltiy
				round(catch.catchment_year - 5, -1) = block_group.year
	where
		st_intersects(block_group.wkb_geometry, catch.wkb_geometry);


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
		births.year as birth_year,
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
	birth_year,
	es_id,
	es_short,
	sum(births_weighted) as total_births
from
	overlap
group by
	census_year,
	catchment_year,
	birth_year,
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

-- select count(*), school_year
-- from sdp.schools_demog_all_years
-- group by school_year;

-- select *
-- from
-- sdp.schools_demog_all_years
-- where school_name like '%Lea%'
-- and grade = '0'
-- ;


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
	births.birth_year,
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
		kindergarten.catchment_year = births.catchment_year;


-- compute demographics by catchment

drop table if exists public.demog_by_catchment;

create table public.demog_by_catchment as

with demog as (
		select
			2010 as "year",
			"state" || county || tract || block_group as geoid,
			total,
			white_alone,
			black_or_african_american_alone,
			asian_alone
		from
			census.census_2010
		
		union all
		
		select
			2015 as "year",
			"state" || county || tract || block_group as geoid,
			total,
			white_alone,
			black_or_african_american_alone,
			asian_alone
		from
			census.acs_2015
	),
	 overlap as (
		select
			overlap.census_year,
			overlap.catchment_year as catchment_year,
		 	demog.year as data_year,
			overlap.geoid,
			overlap.es_id,
			overlap.es_short,
			cast(demog.total as double precision) * overlap.overlap_ratio as total_weighted,
			cast(demog.white_alone as double precision) * overlap.overlap_ratio as white_weighted,
			cast(demog.black_or_african_american_alone as double precision) * overlap.overlap_ratio as black_weighted,
			cast(demog.asian_alone as double precision) * overlap.overlap_ratio as asian_weighted,
			overlap.overlap_ratio
		from
			public.block_group_overlap overlap
		inner join --select * from
		 	sdp.district_school
		 	on
		 		cast(district_school.ulcs_code as text) = overlap.es_id
			and
		 		district_school.start_year = overlap.catchment_year
		inner join
			demog
			on
				demog.geoid = overlap.geoid
			and
				overlap.census_year = 2010
	)
	select
		census_year,
		catchment_year,
	 	data_year,
		es_id,
		es_short,
		sum(total_weighted) as total,
		sum(white_weighted) / sum(total_weighted) as pct_white,
		sum(black_weighted) / sum(total_weighted) as pct_black,
		sum(asian_weighted) / sum(total_weighted) as pct_asian,
		district_school.area_acre,
		sum(total_weighted) / district_school.area_acre as population_density
	from
		overlap
	inner join
		sdp.district_school
		on
			cast(district_school.ulcs_code as text) = overlap.es_id
		and
			district_school.start_year = overlap.catchment_year
	group by
		census_year,
		catchment_year,
	 	data_year,
		es_id,
		es_short,
		district_school.area_acre;


-- Compute average income 

drop table if exists census.income_by_catchment;

create table census.income_by_catchment as

	with income as (
		-- one row per tract per acs_year
		select
			2015 as acs_year,
			tract,
			total_households,
			median_household_income
		from census.acs_tract_2015

		union all

		select
			2010 as acs_year,
			tract,
			total_households,
			median_household_income
		from census.acs_2010
	),
	overlap as (
		select
			acs_year,
			catchment_year,
			es_id,
			es_short,
			tractce,
			overlap_ratio,
			income.tract,
			income.total_households,
			overlap_ratio * cast(income.total_households as double precision) as households_in_catchment,
			income.median_household_income as income
		from
			public.catchment_overlap o
		inner join
			income
			on
				o.tractce = income.tract
			where
				income.total_households != '0'
	),
	catchment_rollup as (
		select
			acs_year,
			catchment_year,
			es_id,
			es_short,
			sum(households_in_catchment) as total_catchment_households,
			-- only count income of tracts that are at least 10% in the catchment
			min(case when overlap_ratio > .10 and cast(income as int) > 0 then cast(income as int) else null end) as min_income,
			max(case when overlap_ratio > .10 then cast(income as int) else null end) as max_income
		from
			overlap
		group by
			acs_year,
			catchment_year,
			es_id,
			es_short
	),
	overlap_rollup as (
		select
			catchment_rollup.acs_year,
			catchment_rollup.catchment_year,
			catchment_rollup.es_id,
			catchment_rollup.es_short,
			overlap.total_households as total_households_in_tract,
			catchment_rollup.total_catchment_households,
			overlap.households_in_catchment,
			case
				when cast(overlap.income as double precision) > 0 then cast(overlap.income as double precision)
				else null
			end as income,
			min_income,
			max_income
		from
			catchment_rollup
		inner join
			overlap
				on
					overlap.acs_year = catchment_rollup.acs_year
				and
					overlap.catchment_year = catchment_rollup.catchment_year
				and
					overlap.es_id = catchment_rollup.es_id
	)
	select
		acs_year,
		catchment_year,
		es_id,
		es_short,
		--sum(households_in_catchment / total_catchment_households) as sum_ratio,
		--sum(income * households_in_catchment / total_catchment_households) as median_household_income,
		cast(sum(income * households_in_catchment / total_catchment_households) as int) as median_household_income,
		max_income - min_income as median_household_income_diff
	from
		overlap_rollup
	group by
		acs_year,
		catchment_year,
		es_id,
		es_short,
		min_income,
		max_income;


-- Compute income deltas within districts between years
drop table if exists census.income_deltas;

create table census.income_deltas as 
select
	catch_1.acs_year as acs_year_1,
	catch_2.acs_year as acs_year_2,
	catch_1.es_id,
	catch_1.es_short,
	catch_1.catchment_year,
	-- these are nominal values and should be pegged to inflation
	-- but I'm moving quickly and just need to see what's viable
	catch_1.median_household_income as median_household_income_1,
	catch_2.median_household_income as median_household_income_2,
	catch_2.median_household_income - catch_1.median_household_income as median_household_income_delta
from
	census.income_by_catchment catch_1
inner join
	census.income_by_catchment catch_2
	on
		catch_1.catchment_year = catch_2.catchment_year
	and
		catch_1.es_id = catch_2.es_id
	and
		catch_1.acs_year = catch_2.acs_year - 5;


-- Compute ratio deltas within catchments between years

drop table if exists public.ratio_delta;

create table public.ratio_delta as
select
	ratio_1.catchment_year as year_1,
	ratio_2.catchment_year as year_2,
	ratio_1.es_id,
	ratio_1.es_short,
	ratio_1.ratio as ratio_1,
	ratio_2.ratio as ratio_2,
	ratio_1.ratio - ratio_2.ratio as ratio_delta,
	ratio_1.total_births as births_1,
	ratio_2.total_births as births_2,
	ratio_1.total_births - ratio_2.total_births as births_delta,
	ratio_1.total_enrolled as enrolled_1,
	ratio_2.total_enrolled as enrolled_2,
	ratio_1.total_enrolled - ratio_2.total_enrolled as enrolled_delta
from
	public.births_to_enrollment ratio_1
inner join
	public.births_to_enrollment ratio_2
	on
		ratio_1.es_id = ratio_2.es_id
	and
		ratio_1.catchment_year - 1 = ratio_2.catchment_year;



-- check if district schools overlap with a charter school

drop table if exists sdp.charter_catchment;

create table sdp.charter_catchment as

	with charters as(
		select
			school_year,
			cast(substring(school_year, 1, 4) as int) as catchment_year,
			cast(ulcs_code as character varying) as es_id,
			current_grade_span_served,
			lower(governance) as school_region
		from
			sdp.school
		where
			lower(governance) = 'charter'
		and
			current_grade_span_served like '%00%'
		and
			year_closed = 'open'
	)
	select
		catch.catchment_year,
		catch.es_id,
		catch.es_short,
		charters.school_region,
		catch.wkb_geometry
	from
		sdp.catchments_all_years as catch
	inner join
		charters
		using(catchment_year, es_id);
	

-- find intersection of kindergarten charter school locations and sdp kindergartens

drop table if exists sdp.charter_catchment_overlap;

create table sdp.charter_catchment_overlap as
	with charters as(
		select
			school_year,
			cast(substring(school_year, 1, 4) as int) as catchment_year,
			cast(ulcs_code as character varying) as es_id,
			current_grade_span_served,
			lower(governance) as school_region
		from
			sdp.school
		where
			lower(governance) = 'charter'
		and
			current_grade_span_served like '%00%'
		and
			year_closed = 'open'
	),
	charter_geom as (
		select
			catch.catchment_year,
			catch.es_id,
			catch.es_short,
			charters.school_region,
			catch.wkb_geometry
		from
			sdp.catchments_all_years as catch
		inner join
			charters
			using(catchment_year, es_id)
	),
	charter_point as (
		select
			start_year as catchment_year,
			cast(ulcs_code as character varying) as es_id,
			geo_id
		from 
			sdp.school_location
		where
			gps_location is not null
		and
			governance = 'charter'
		and
			current_grade_span_served like '%00%'
		
		union all
		
		-- quick assumption that no schools have moved. Need to clean this up
		select
			2016 as catchment_year,
			cast(ulcs_code as character varying) as es_id,
			geo_id
		from 
			sdp.school_location
		where
			gps_location is not null
		and
			governance = 'charter'
		and
			current_grade_span_served like '%00%'
		and
			start_year = 2017
	),
	district_geom as (
		select 
			catch.catchment_year,
			catch.es_id,
			catch.es_short,
			distict.school_region,
			catch.wkb_geometry
		from
			sdp.catchments_all_years as catch
		inner join
			sdp.district_school as distict
			on
				distict.start_year = catch.catchment_year
			and
				cast(distict.ulcs_code as character varying) = catch.es_id
	)
	select
		district.catchment_year,
		district.es_id,
		district.es_short,
		district.school_region,
		charter.es_id as charter_es_id,
		charter.es_short as charter_es_short,
		case
			when charter.es_id is not null then 1
			else 0
		end as adjacent,
		case
			when charter_point.es_id is not null then 1
			else 0
		end as inside,
		district.wkb_geometry
	from
		district_geom as district
	left join
		charter_point
		on
			district.catchment_year = charter_point.catchment_year
		and
			st_intersects(district.wkb_geometry, charter_point.geo_id)
	left join
		charter_geom as charter
		on
			district.catchment_year = charter.catchment_year
		and
			st_intersects(district.wkb_geometry, charter.wkb_geometry);


-- distance to nearest charter school

drop table if exists sdp.school_charter_distance;

create table sdp.school_charter_distance as
	with charters as(
		select
			school_year,
			cast(substring(school_year, 1, 4) as int) as catchment_year,
			cast(ulcs_code as character varying) as es_id,
			current_grade_span_served,
			lower(governance) as school_region
		from
			sdp.school
		where
			lower(governance) = 'charter'
		and
			current_grade_span_served like '%00%'
		and
			year_closed = 'open'
	),
	charter_point as (
		select
			start_year as catchment_year,
			cast(ulcs_code as character varying) as es_id,
			geo_id
		from 
			sdp.school_location
		where
			gps_location is not null
		and
			governance = 'charter'
		and
			current_grade_span_served like '%00%'
		
		union all
		
		-- quick assumption that no schools have moved
		select
			2016 as catchment_year,
			cast(ulcs_code as character varying) as es_id,
			geo_id
		from 
			sdp.school_location
		where
			gps_location is not null
		and
			governance = 'charter'
		and
			current_grade_span_served like '%00%'
		and
			start_year = 2017
	),
	district_point as (
		select
			start_year as catchment_year,
			cast(ulcs_code as character varying) as es_id,
			geo_id
		from
			sdp.school_location
		where
			gps_location is not null
		and
			governance = 'district'
		and
			current_grade_span_served like '%00%'
		
		union all
		
		-- quick assumption no schools have moved
		
		select
			2016 as catchment_year,
			cast(ulcs_code as character varying) as es_id,
			geo_id
		from
			sdp.school_location
		where
			gps_location is not null
		and
			governance = 'district'
		and
			current_grade_span_served like '%00%'
		and
			start_year = 2017
	)
	select
		catchment_year,
		district_point.es_id,
		min(abs(st_length(st_makeline(district_point.geo_id, charter_point.geo_id)))) as charter_distance
	from
		district_point
	left join
		charter_point
		using(catchment_year)
	group by
		catchment_year,
		district_point.es_id;


-- build a table to bring together all the variables I want to explore

drop table if exists public.comparison;

create table public.comparison as
	with charter as (
		select
			catchment_year,
			es_id,
			case when sum(adjacent) > 0 then 1 else 0 end as adjacent,
			case when sum(inside) > 0 then 1 else 0 end as inside
		from
			sdp.charter_catchment_overlap
		group by
			catchment_year,
			es_id
	),
	grade_3 as (
		select
			cast(school_year as int) as catchment_year,
			rpad(cast(school_code as text), 4, '0') as es_id,
			school_name,
			grade,
			sum(cast(case when levels_3_and_4_percent = 's' then '0' else levels_3_and_4_percent end as double precision)) as pass_percent
		from sdp.score 
		where grade = '3'
		and subject = 'ELA'
		and ("group" = 'All Students' or "group" is null)
		group by
			school_year,
			school_code,
			school_name,
			grade
	)
	select
		birth.catchment_year,
		birth.es_id,
		birth.ratio,
		demog.pct_white,
		demog.pct_black,
		demog.pct_asian,
		income.median_household_income,
		income_d.median_household_income_delta as income_delta,
		ratio_d.ratio_delta,
		school.school_region as region,
		charter.adjacent as next_to_charter,
		grade_3.pass_percent,
		birth.total_births,
		birth.total_enrolled,
		ratio_d.enrolled_delta,
		ratio_d.births_delta,
		charter.inside as contains_charter,
		income.median_household_income_diff,
		demog.population_density,
		school_tenure.cumulative_tenure,
		school_charter_distance.charter_distance
	from
		public.births_to_enrollment birth
	inner join
		public.demog_by_catchment demog
			using(catchment_year, es_id)
	inner join
		census.income_by_catchment income
			using(catchment_year, es_id)
	left join
		charter
			using(catchment_year, es_id)
	left join
		grade_3
			using(catchment_year, es_id)
	left join
		sdp.school_tenure
			using(catchment_year, es_id)
	left join
		sdp.school_charter_distance
			using(catchment_year, es_id)
	inner join
		sdp.district_school school
		on
			school.start_year = birth.catchment_year
		and
			cast(school.ulcs_code as text) = birth.es_id
	left join
		census.income_deltas income_d
			using(catchment_year, es_id)
	left join
		public.ratio_delta ratio_d
			on
				ratio_d.es_id = birth.es_id
			and
				ratio_d.year_1 = birth.catchment_year
	where income.acs_year = 2010
	and demog.census_year = 2010;