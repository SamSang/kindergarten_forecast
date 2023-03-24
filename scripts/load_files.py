#!python
"""
Script to load data about births to a postgres database

NOTE
I've removed incorrect headers on these files for a clean load to a data frame.
Source: https://web.archive.org/web/20181107034101/https://www.phila.gov/health/Commissioner/VitalStatistics.html

Before runnin this script, you need to create the database and schemas.
In the database, don't forget CREATE EXTENSION postgis;
Create sdp.sdp and
       sdp.census
(or change the variables below)
"""

import openpyxl
import os
import pandas
import re
from sqlalchemy import create_engine
import subprocess
from tqdm import tqdm
import urllib.request
import zipfile

census_key = '' # TODO add your key here

def get_csvs(file_path):
    return list(filter(lambda f: re.search(r"\.csv$", f), os.listdir(file_path)))

def clean_col(col: str):
    col = col.lower()
    col = col.replace('<', '')
    col = col.replace(',', '')
    col = col.replace('.', '')
    col = col.replace('-', '_')
    col = col.replace('\n', '_')
    col = col.replace('#', '')
    col = col.replace('%', '')
    col = col.replace('  ', '_')
    col = col.strip()
    col = col.replace(' ', '_')
    return col

def main():
    user = input('user: ')
    #pw = input('password: ')
    db = 'sdp'
    census_schema = 'census'
    sdp_schema = 'sdp'
    engine = create_engine(f"postgresql+psycopg2://{user}@localhost:5432/{db}")

    print("Loading births files...")
    births_path = os.path.join('..',"data", "births")
    births_files = get_csvs(births_path)
    for births_file in tqdm(births_files):
        year = births_file[0:4]
        df = pandas.read_csv(os.path.join(births_path, births_file))
        df.insert(0, 'census_year', year)
        df.rename(columns=clean_col, inplace=True)

        table_name = f'births_{year}'
        df.to_sql(
            name=table_name,
            con=engine,
            schema='census',
            if_exists='replace',
        )

    print("Loading school district demographics files...")
    # All demog data will live in one directory
    demog_data_path = os.path.join('..', 'data', 'schools', 'demog')
    
    # load student demog data in csv format
    demog_csv_url = "https://cdn.philasd.org/offices/performance/Open_Data/School_Information/Enrollment_Demographics_School/{year}%20Enrollment%20&%20Demographics.csv"

    demog_years_csv = [
        '2019-2020',
    ]

    for year in tqdm(demog_years_csv):
        url = demog_csv_url.format(year=year)
        download_file = f'{year}_Enrollment_Demographics.csv'
        download_path = os.path.join(demog_data_path, download_file)
        urllib.request.urlretrieve(url, download_path)
        table_name = clean_col(f'schools_demog_{year}')
        df = pandas.read_csv(
            download_path,
            sep=',',
            )
        df.rename(columns=clean_col, inplace=True)
        df.to_sql(
            name=table_name,
            con=engine,
            schema='sdp',
            if_exists='replace',
        )

    # load student demog data from xlsx format
    demog_xlsx_url = 'https://cdn.philasd.org/offices/performance/Open_Data/School_Information/Enrollment_Demographics_School/{year}%20Enrollment%20&%20Demographics.xlsx'

    # load data in clean format first
    demog_years_xlsx = [
        '2018-2019',
    ]

    for year in tqdm(demog_years_xlsx):
        url = demog_xlsx_url.format(year=year)
        download_file = f'{year}_Enrollment_Demographics.xlsx'
        download_path = os.path.join(demog_data_path, download_file)
        urllib.request.urlretrieve(url, download_path)

        workbook = openpyxl.load_workbook(download_path)
        worksheet = workbook['Sheet1']
        data = worksheet.values
        cols = next(data)[0:]
        data = list(data)
        df = pandas.DataFrame(data, columns=cols)

        table_name = clean_col(f'schools_demog_{year}')
        df.rename(columns=clean_col, inplace=True)
        df.to_sql(
            name=table_name,
            con=engine,
            schema='sdp',
            if_exists='replace',
        )

    demog_years_xlsx = [
        '2017-2018',
        '2016-2017',
    ]

    for year in tqdm(demog_years_xlsx):
        url = demog_xlsx_url.format(year=year)
        download_file = f'{year}_Enrollment_Demographics.xlsx'
        download_path = os.path.join(demog_data_path, download_file)
        urllib.request.urlretrieve(url, download_path)

        workbook = openpyxl.load_workbook(download_path)

        # process sheet(s) we need

        # Ethnicity
        ethnicity = workbook['Ethnicity'].values
        # skip 4 lines
        for i in range(4):
            next(ethnicity)
        subtabs = next(ethnicity)[1:21]
        ethnicity_cols = list(next(ethnicity)[1:21])
        # match subtabs to columns to build something like "Hispanic_percent"
        for label_idx, label in enumerate(subtabs):
            if label:
                for col_idx in range(len(ethnicity_cols)):
                    if (col_idx - 1) // 2 == (label_idx) // 2:
                        ethnicity_cols[col_idx] = label.split('\n')[0] + '_' + ethnicity_cols[col_idx]
        ethnicity = [r[1:21] for r in list(ethnicity)]

        df_ethnicity = pandas.DataFrame(ethnicity, columns=ethnicity_cols)
        df_ethnicity.rename(columns=clean_col, inplace=True)
        # if we merge to another sheet, remove duplicate columns to avoid muddled names
        #df_ethnicity = df_ethnicity.drop(columns=['total_enrolled', 'learning_network', 'school_name'])

        # merge both dataframes together so we only load one table
        #df = pandas.merge(something, df_ethnicity, how='left', on=['school_id', 'grade'])
        df = df_ethnicity
        df .insert(0, 'school_year', year)

        table_name = clean_col(f'schools_demog_{year}')
        df.to_sql(
            name=table_name,
            con=engine,
            schema='sdp',
            if_exists='replace',
        )

    print("Processing SDP list of schools...")
    list_data_path = os.path.join('..', 'data', 'schools', 'list')
    list_table_name = clean_col(f'school')

    print("Processing xlsx format files")
    list_urls = [
        ("https://cdn.philasd.org/offices/performance/Open_Data/School_Information/School_List/Longitudinal%20School%20List%20(20171128).xlsx", "Sheet1", "multi"),
        ("https://cdn.philasd.org/offices/performance/Open_Data/School_Information/School_List/2017-2018%20Master%20School%20List%20(20180611).xlsx", "Master School List", "2017-2018"),
    ]
    for index, list_tuple in tqdm(enumerate(list_urls)):
        list_url, list_sheet, list_year = list_tuple
        list_historical_download_file = os.path.basename(list_url).replace("%20", "_")
        list_historical_download_path = os.path.join(list_data_path, list_historical_download_file)
        urllib.request.urlretrieve(list_url, list_historical_download_path)

        list_historical_workbook = openpyxl.load_workbook(list_historical_download_path)

        list_historical = list_historical_workbook[list_sheet].values

        list_historical_cols = list(next(list_historical)[0:27])

        list_historical = [r[0:27] for r in list(list_historical)]

        df_list_historical = pandas.DataFrame(list_historical, columns=list_historical_cols)
        df_list_historical.rename(columns=clean_col, inplace=True)

        list_convert_cols = {
            "grade_span": "current_grade_span_served",
        }
        df_list_historical.rename(columns=list_convert_cols, inplace=True)

        list_keep_cols = [
            "school_year",
            "pa_code",
            "ulcs_code",
            "admission_type",
            "current_grade_span_served",
            "school_level",
            "governance",
            "school_region_code",
            "school_region",
            "year_closed",
        ]
        df_list_historical = df_list_historical.filter(list_keep_cols, axis=1)

        if list_year != "multi":
            # make the school_year column equal the value we passed in
            df_list_historical["school_year"] = pandas.Series([list_year for x in range(len(df_list_historical.index))])

        list_mode = "append"
        if index == 0:
            list_mode = "replace"

        df_list_historical.to_sql(
            name=list_table_name,
            con=engine,
            schema='sdp',
            if_exists=list_mode,
        )

    print("Processing csv format files")
    # TODO clean up the repetitiveness of this section compared to the xlsx section
    list_csv_files = [
        "https://cdn.philasd.org/offices/performance/Open_Data/School_Information/School_List/2018-2019%20Master%20School%20List%20(20190510).csv",
        "https://cdn.philasd.org/offices/performance/Open_Data/School_Information/School_List/2019-2020%20Master%20School%20List%20(20201123).csv",
    ]
    for list_url in tqdm(list_csv_files):
        list_historical_download_file = os.path.basename(list_url).replace("%20", "_")
        year = list_historical_download_file[0:9]
        list_historical_download_path = os.path.join(list_data_path, list_historical_download_file)
        urllib.request.urlretrieve(list_url, list_historical_download_path)

        df_list_historical = pandas.read_csv(list_historical_download_path)
        df_list_historical.insert(0, 'school_year', year)
        df_list_historical.rename(columns=clean_col, inplace=True)

        list_keep_cols = [
            "school_year",
            "pa_code",
            "ulcs_code",
            "admission_type",
            "current_grade_span_served",
            "school_level",
            "governance",
            "school_region_code",
            "school_region",
            "year_closed",
        ]
        df_list_historical = df_list_historical.filter(list_keep_cols, axis=1)

        df_list_historical.to_sql(
            name=list_table_name,
            con=engine,
            schema='sdp',
            if_exists="append",
        )

    print("Processing census tract shape files...")
    # TODO consider using the ogr python interface
    # http://pcjericks.github.io/py-gdalogr-cookbook/vector_layers.html#create-a-postgis-table-from-wkt
    print("Processing 2010")
    subprocess.run(
        [
            'ogr2ogr',
            '-f', 'PostgreSQL',
            f'Pg:dbname={db} host=localhost port=5432 user={user}',
            '-lco', f'SCHEMA={census_schema}',
            '-lco', 'OVERWRITE=YES',
            '-nlt', 'PROMOTE_TO_MULTI',
            '-sql', "select 2010 as year, tractce10 as tractce, geoid10 as geoid, name10 as name, aland10 as aland, awater10 as awater from tl_2010_42101_tract10 where countyfp10 = '101'",
            '-t_srs', 'EPSG:2272',
            '-nln', 'tract',
            '/vsizip/vsicurl/https://www2.census.gov/geo/tiger/TIGER2010/TRACT/2010/tl_2010_42101_tract10.zip',
        ],
        check=True,
    )

    print("Processing census block group shape files...")
    print("Processing 2010")
    subprocess.run(
        [
            'ogr2ogr',
            '-f', 'PostgreSQL',
            f'Pg:dbname={db} host=localhost port=5432 user={user}',
            '-lco', f'SCHEMA={census_schema}',
            '-lco', 'OVERWRITE=YES',
            '-nlt', 'PROMOTE_TO_MULTI',
            '-sql', "select 2010 as year, tractce10 as tractce, blkgrpce10 as blkgrpce, geoid10 as geoid, namelsad10 as name, aland10 as aland, awater10 as awater from tl_2010_42101_bg10 where countyfp10 = '101'",
            '-t_srs', 'EPSG:2272',
            '-nln', 'block_group',
            '/vsizip/vsicurl/https://www2.census.gov/geo/tiger/TIGER2010/BG/2010/tl_2010_42101_bg10.zip',
        ],
        check=True,
    )

    print("Process block group data...")
    """
    Documentation on census 2010 race columns:
        https://api.census.gov/data/2010/dec/sf1/groups/P3.html
    Documentation on acs 2015 race columns:
        https://www2.census.gov/programs-surveys/acs/summary_file/2015/documentation/user_tools/ACS2015_Table_Shells.xlsx
    """
    block_group_years = {
        "census_2010": {
            "url": "https://api.census.gov/data/2010/dec/sf1?get=NAME,P003001,P003002,P003003,P003004,P003005,P003006,P003007,P003008&for=block%20group:*&in=state:42&in=county:101&in=tract:*&key={census_key}",
            "fields": [
                "Name",
                "Total",
                "White alone",
                "Black or African American alone",
                "American Indian and Alaska Native alone",
                "Asian alone",
                "Native Hawaiian and Other Pacific Islander alone",
                "Some Other Race alone",
                "Two or More Races",
                "state",
                "county",
                "tract",
                "block_group",
            ],
        },
        "acs_2010": {
            "url": "https://api.census.gov/data/2010/acs/acs5?get=NAME,B00002_001E,B19013_001E&for=tract:*&in=state:42&in=county:101&key={census_key}",
            "fields": [
                "Name",
                "Total Households",
                "Median Household Income",
                "state",
                "county",
                "tract",
            ],
        },
        "acs_2015": {
            "url": "https://api.census.gov/data/2015/acs/acs5?get=NAME,B02001_001E,B02001_002E,B02001_003E,B02001_004E,B02001_005E,B02001_006E,B02001_007E,B02001_008E&for=block%20group:*&in=state:42&in=county:101&in=tract:*&key={census_key}",
            "fields": [
                "Name",
                "Total",
                "White alone",
                "Black or African American alone",
                "American Indian and Alaska Native alone",
                "Asian alone",
                "Native Hawaiian and Other Pacific Islander alone",
                "Some other race alone",
                "Two or more races",
                "state",
                "county",
                "tract",
                "block_group",
            ],
        },
    }
    for year in block_group_years:
        print(f"Processing {year}")
        url = block_group_years[year]['url']
        fields = block_group_years[year]['fields']

        df = pandas.read_json(url.format(census_key=census_key))
        # df.iloc[0] # TODO save census designations as comments on the columns
        df.columns = fields
        df.rename(columns=clean_col, inplace=True)
        df = df.drop(axis='index', index=0)
        
        df.to_sql(
            name=year,
            con=engine,
            schema='census',
            if_exists='replace',
        )


    # TODO add the year to the sdp shape?
    print(f'Process sdp catchment shape files...') 
    catchment_years = [
        '1617',
        '1718',
        '1819',
        '1920',
    ]

    # download the zip file with everything in it
    sdp_shapes_url = 'https://cdn.philasd.org/offices/performance/Open_Data/School_Information/School_Catchment/SDP_Catchment_All_Years.zip'
    sdp_data_path = os.path.join('..', 'data', 'schools')
    sdp_shapes_path = os.path.join(sdp_data_path, os.path.basename(sdp_shapes_url))
    urllib.request.urlretrieve(sdp_shapes_url, sdp_shapes_path)

    # unzip the file with all years of shapes
    unzip_dir = os.path.basename(sdp_shapes_url).rstrip('.zip')
    unzip_path = os.path.join(sdp_data_path, unzip_dir)
    with zipfile.ZipFile(sdp_shapes_path, 'r') as f:
        f.extractall(unzip_path)

    for year in tqdm(catchment_years):

        # extract the files for that catchment year
        current_file_name = f'SDP_Catchment_{year}.zip'
        current_unzip_path = os.path.join(unzip_path, current_file_name.rstrip('.zip'))
        with zipfile.ZipFile(os.path.join(unzip_path, current_file_name)) as f:
            f.extractall(current_unzip_path)
        
        # then load the shapefiles
        subprocess.run(
            [
                'ogr2ogr',
                '-f', 'PostgreSQL',
                f'Pg:dbname={db} host=localhost port=5432 user={user}',
                '-lco', f'SCHEMA={sdp_schema}',
                '-lco', 'OVERWRITE=YES',
                '-nlt', 'PROMOTE_TO_MULTI',
                '-t_srs', 'EPSG:2272',
                '-lco', 'precision=NO',
                os.path.join(
                    current_unzip_path,
                    f'Catchment_ES_20{year[0:2]}-{year[2:4]}',
                    f'Catchment_ES_20{year[0:2]}.shp')
            ],
            check=True,
        )

    engine.dispose()

if __name__ == '__main__':
    main()