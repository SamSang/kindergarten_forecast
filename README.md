# kindergarten_forecast

View a [preview of the notebook](https://htmlpreview.github.io/?https://github.com/SamSang/kindergarten_forecast/blob/main/FinalReport.html)!

This is (meant to be) a graduate-level introductory statistics final project.

The initial idea was to use census data to predict kindergarten enrollment in School District of Philadelphia neighborhood schools.
The more valuable part of this project will probably the data pipeline.

## What do I do first?

1. Install Postgress
  - Don't forget the PostGIS extension
2. Create a database called `sdp`
3. In `sdp`, create schemas
  - `sdp`
  - `census`
4. Create a python virtual environment using `requirements.txt`
  - Don't forget to activate your virtual environment before running `load_data.py`

## What's here?

|File|Sequence|Description|
|-|-|-|
|`load_data.py`|1|Downloads and loads data to the database|
|`transforms.sql`|2|Transforms the tables in the databse|
|`FinalReport.Rmd`|3|R Markdown of analysis|
|`FinalReport.html`|4|Knit result of `FinalReport.Rmd`

Good luck!
