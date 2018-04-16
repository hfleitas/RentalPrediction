EXEC sp_configure 'external scripts enabled', 1;
RECONFIGURE WITH OVERRIDE
-- https://microsoft.github.io/sql-ml-tutorials/python/rentalprediction/
-- https://sqlchoice.blob.core.windows.net/sqlchoice/TutorialDB.bak

USE master;
GO
RESTORE DATABASE TutorialDB
   FROM DISK = 'C:\users\hfleitas\downloads\TutorialDB.bak'
   WITH
   MOVE 'TutorialDB' TO 'C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\TutorialDB.mdf'
   ,MOVE 'TutorialDB_log' TO 'C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\TutorialDB.ldf';
GO

USE [master]
GO
ALTER DATABASE [TutorialDB] SET COMPATIBILITY_LEVEL = 140 --2017
ALTER DATABASE [TutorialDB] SET RECOVERY SIMPLE WITH NO_WAIT
GO

USE tutorialdb;
SELECT * FROM [dbo].[rental_data];


USE TutorialDB;
DROP TABLE IF EXISTS rental_py_models; --did not exist.
GO
CREATE TABLE rental_py_models (
	model_name VARCHAR(30) NOT NULL DEFAULT('default model') PRIMARY KEY,
	model VARBINARY(MAX) NOT NULL
);
GO

-- Stored procedure that trains and generates a Python model using the rental_data and a decision tree algorithm
CREATE or alter PROCEDURE generate_rental_py_model (@trained_model varbinary(max) OUTPUT)
AS
BEGIN
    EXECUTE sp_execute_external_script
      @language = N'Python'
    , @script = N'
from sklearn.linear_model import LinearRegression
import pickle

df = rental_train_data

# Get all the columns from the dataframe.
columns = df.columns.tolist()

# Store the variable well be predicting on.
target = "RentalCount"

# Initialize the model class.
lin_model = LinearRegression()

# Fit the model to the training data.
lin_model.fit(df[columns], df[target])

#Before saving the model to the DB table, we need to convert it to a binary object
trained_model = pickle.dumps(lin_model)'

, @input_data_1 = N'select "RentalCount", "Year", "Month", "Day", "WeekDay", "Snow", "Holiday" from dbo.rental_data where Year < 2015'
, @input_data_1_name = N'rental_train_data'
, @params = N'@trained_model varbinary(max) OUTPUT'
, @trained_model = @trained_model OUTPUT;
END;
GO

--STEP 3 - Save model to table
TRUNCATE TABLE rental_py_models;

DECLARE @model VARBINARY(MAX);

EXEC generate_rental_py_model @model OUTPUT;
INSERT INTO rental_py_models (model_name, model) VALUES('linear_model', @model); --7sec
select * from rental_py_models

--STEP 4 - CREATE PROC FOR PREDICTION.
DROP PROCEDURE IF EXISTS py_predict_rentalcount;
GO
CREATE PROCEDURE py_predict_rentalcount (@model varchar(100))
AS
BEGIN
	DECLARE @py_model varbinary(max) = (select model from rental_py_models where model_name = @model);

	EXEC sp_execute_external_script
				@language = N'Python',
				@script = N'

# Import the scikit-learn function to compute error.
from sklearn.metrics import mean_squared_error
import pickle
import pandas as pd

rental_model = pickle.loads(py_model)

df = rental_score_data

# Get all the columns from the dataframe.
columns = df.columns.tolist()

# variable we will be predicting on.
target = "RentalCount"

# Generate our predictions for the test set.
lin_predictions = rental_model.predict(df[columns])
print(lin_predictions)

# Compute error between our test predictions and the actual values.
lin_mse = mean_squared_error(lin_predictions, df[target])
#print(lin_mse)

predictions_df = pd.DataFrame(lin_predictions)

OutputDataSet = pd.concat([predictions_df, df["RentalCount"], df["Month"], df["Day"], df["WeekDay"], df["Snow"], df["Holiday"], df["Year"]], axis=1)
'
, @input_data_1 = N'Select "RentalCount", "Year" ,"Month", "Day", "WeekDay", "Snow", "Holiday"  from rental_data where Year = 2015'
, @input_data_1_name = N'rental_score_data'
, @params = N'@py_model varbinary(max)'
, @py_model = @py_model
with result sets (("RentalCount_Predicted" float, "RentalCount" float, "Month" float,"Day" float,"WeekDay" float,"Snow" float,"Holiday" float, "Year" float));

END;
GO

--TABLE FOR STORING PREDICTIONS
DROP TABLE IF EXISTS [dbo].[py_rental_predictions];
GO
--Create a table to store the predictions in
CREATE TABLE [dbo].[py_rental_predictions](
 [RentalCount_Predicted] [int] NULL,
 [RentalCount_Actual] [int] NULL,
 [Month] [int] NULL,
 [Day] [int] NULL,
 [WeekDay] [int] NULL,
 [Snow] [int] NULL,
 [Holiday] [int] NULL,
 [Year] [int] NULL
) ON [PRIMARY]
GO

--EXECUTE PROC TO PREDICT RENTAL COUNTS
TRUNCATE TABLE py_rental_predictions;
--Insert the results of the predictions for test set into a table
INSERT INTO py_rental_predictions
EXEC py_predict_rentalcount 'linear_model';

-- Select contents of the table
SELECT * FROM py_rental_predictions;


-- +--------------------------------------+
-- | PREDICT USING NATIVE SCORING! - NEW! |
-- +--------------------------------------+
USE TutorialDB;

--STEP 1 - Setup model table for storing the model
DROP TABLE IF EXISTS rental_models;
GO
CREATE TABLE rental_models (
                model_name VARCHAR(30) NOT NULL DEFAULT('default model'),
                lang VARCHAR(30),
				model VARBINARY(MAX),
				native_model VARBINARY(MAX),
				PRIMARY KEY (model_name, lang)

);
GO

--STEP 2 - Train model using revoscalepy rx_dtree or rxlinmod
DROP PROCEDURE IF EXISTS generate_rental_py_native_model;
go
CREATE PROCEDURE generate_rental_py_native_model (@model_type varchar(30), @trained_model varbinary(max) OUTPUT)
AS
BEGIN
    EXECUTE sp_execute_external_script
      @language = N'Python'
    , @script = N'
from revoscalepy import rx_lin_mod, rx_serialize_model, rx_dtree
from pandas import Categorical
import pickle

rental_train_data["Holiday"] = rental_train_data["Holiday"].astype("category")
rental_train_data["Snow"] = rental_train_data["Snow"].astype("category")
rental_train_data["WeekDay"] = rental_train_data["WeekDay"].astype("category")

if model_type == "linear":
	linmod_model = rx_lin_mod("RentalCount ~ Month + Day + WeekDay + Snow + Holiday", data = rental_train_data)
	trained_model = rx_serialize_model(linmod_model, realtime_scoring_only = True);
if model_type == "dtree":
	dtree_model = rx_dtree("RentalCount ~ Month + Day + WeekDay + Snow + Holiday", data = rental_train_data)
	trained_model = rx_serialize_model(dtree_model, realtime_scoring_only = True);
'

    , @input_data_1 = N'select "RentalCount", "Year", "Month", "Day", "WeekDay", "Snow", "Holiday" from dbo.rental_data where Year < 2015'
    , @input_data_1_name = N'rental_train_data'
    , @params = N'@trained_model varbinary(max) OUTPUT, @model_type varchar(30)'
	, @model_type = @model_type
    , @trained_model = @trained_model OUTPUT;
END;
GO

--STEP 3 - Save model to table

--Line of code to empty table with models
-- SELECT * FROM RENTAL_MODELS
-- TRUNCATE TABLE rental_models;

--Save Linear model to table
DECLARE @model VARBINARY(MAX);
EXEC generate_rental_py_native_model "linear", @model OUTPUT;
INSERT INTO rental_models (model_name, native_model, lang) VALUES('linear_model', @model, 'Python');

--Save DTree model to table
DECLARE @model2 VARBINARY(MAX);
EXEC generate_rental_py_native_model "dtree", @model2 OUTPUT;
INSERT INTO rental_models (model_name, native_model, lang) VALUES('dtree_model', @model2, 'Python');

-- Look at the models in the table
SELECT * FROM rental_models;
GO

--STEP 4  - Use the native PREDICT (native scoring) to predict number of rentals for both models
DECLARE @model VARBINARY(MAX) = (SELECT TOP(1) native_model FROM dbo.rental_models WHERE model_name = 'linear_model' AND lang = 'Python');
SELECT d.*, p.* FROM PREDICT(MODEL = @model, DATA = dbo.rental_data AS d) WITH(RentalCount_Pred float) AS p
order by [year] desc, [month] desc, [day] desc;
GO

--Native scoring with dtree model
DECLARE @model VARBINARY(MAX) = (SELECT TOP(1) native_model FROM dbo.rental_models WHERE model_name = 'dtree_model' AND lang = 'Python');
SELECT d.*, p.* FROM PREDICT(MODEL = @model, DATA = dbo.rental_data AS d) WITH(RentalCount_Pred float) AS p 
order by [year] desc, [month] desc, [day] desc;
GO


select * from rental_data order by year