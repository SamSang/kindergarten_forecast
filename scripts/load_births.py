#!python
"""
Script to load data about births to a postgres database

NOTE
I've removed incorrect headers on these files for a clean load to a data frame.

"""

import os
import re
import pandas
from sqlalchemy import create_engine


births_path = os.path.join("data", "births")
births_files = list(filter(lambda f: re.search(r"\.csv$", f), os.listdir(births_path)))

def clean_col(col: str):
    col = col.lower()
    col = col.replace('<', '')
    col = col.replace(',', '')
    col = col.replace('.', '')
    col = col.replace(' ', '_')
    return col

def main():
    user = input('user: ')
    pw = input('password: ')
    engine = create_engine(f"postgresql+psycopg2://{user}:{pw}@localhost:5432/sdp")
    for births_file in births_files:
        table_name = 'births_' + births_file[0:4]
        df = pandas.read_csv(os.path.join(births_path, births_file))
        df.rename(columns=clean_col, inplace=True)
        df.to_sql(
            name=table_name,
            con=engine,
            schema='census',
            if_exists='replace',
        )
    engine.dispose()

if __name__ == '__main__':
    main()