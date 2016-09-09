/*
Copyright (c) 2016 SQL Fairy http://sqlfairy.com.au

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

/*
---------------------Magic undelete for SQL Server v2.2------------------------------------------------------

For detailed information on this script please visit http://www.sqlfairy.com.au/2015/10/sql-fairy-magic-undelete/

The following scripts written by mick@sqlfairy.com.au http://sqlfairy.com.au automate the process of automatically archiving all delete operations
from a database by adding AFTER DELETE triggers.  The code automatically maintains the state of the triggers and archive tables following schema updates.

*/
----------CHANGE HISTORY-----------

--Mick 29-10-2012----Version 1.0
--
/*
Version 2.0 Updates from 10/10/2015 - 12/10/2015 

	* Change query generation to add quotename[] to places required.  Found that the script fell over on a column named Schema which is a reserved word.
		Could (probably should) HAVE added quotename throughout. 

	* Make updates to resolve problems with non DBO schema tables.  Found that there were hardcoded dbo. values in generated script.  This has been changed ftm to 
		use the supplied @Schemaname param.  A future version will most likely eliminate this parameter in favour of covering all schemas as the use case has changed

	* Add 'SET NOCOUNT ON' to triggers

	* Refactor scripts using xml string concatenation so that we can do away with the dependency on strconcat and therfore .net 

	* Improve table comparison to ensure that changes other than column name and base data type are detected (and new Archive tables created).

	* Refactor scripts to add delete triggers for all schemas (except the actual archive schemas).  Generate a schema defaulting to zzzArchiveSchemaname 
		for each schema.

	* Extend FixNTextFields (and rename?) so that additional unsupported types are covered (now [FixDeprecatedColumnTypes])

	* Extend EnableDeleteTriggers to check if there are any unsupported data types and if so print a warning message, detailed info on correcting the problem 
		and exit

	* Change default mode to debug. Add some additional information

	* Update DisableDeleteTriggers proc to remove all triggers.  Ensure that it works with the same default debug mode.

	* Update description of scripts above
		
TODO:
	
	* Add an option to run for just a particular table

	* Improve optional DDL trigger so that it calls EnableDeleteTriggers with (yet to be added) single table parameter.  Should reduce
		my reservations about putting a DDL trigger in place.

	* Add support for maintaining exclusions.  Store this in a table per delete schema.


*/
	
--------------------------------------------------------------------------------------------------------------

--Add a function that we will use to compare tables to see if they need to be re-created		
IF (SELECT OBJECT_ID('udf_TableHash')) IS NULL EXEC('create function udf_TableHash (@placeholder int) returns int begin RETURN 1+1 end')
GO
ALTER FUNCTION udf_TableHash 
	(	@Schema SYSNAME
	,	@Table SYSNAME
	)
	RETURNS VARCHAR(MAX)
AS
BEGIN
--Generate a hash for specified schema and table

--Remove square brackets so we're not comparing apples with goats!
SET @Schema = REPLACE(REPLACE(@Schema, '[',''),']','')
SET @Table = REPLACE(REPLACE(@Table, '[',''),']','')

RETURN (
		SELECT TOP(1)
			(select		
				HASHBYTES
						('md5', 
						CAST(ISNULL(MyCols.[name], '') AS VARCHAR(MAX)) +
						CAST(ISNULL(MyCols.[system_type_id], '') AS VARCHAR(MAX)) +
						CAST(ISNULL(MyCols.[user_type_id], '') AS VARCHAR(MAX)) +
						CAST(ISNULL(MyCols.[max_length], '') AS VARCHAR(MAX)) +
						CAST(ISNULL(MyCols.[precision], '') AS VARCHAR(MAX)) +
						CAST(ISNULL(MyCols.[scale], '') AS VARCHAR(MAX)) +
						CAST(ISNULL(MyCols.[collation_name], '') AS VARCHAR(MAX)) +
						CAST(ISNULL(MyCols.[is_nullable], '') AS VARCHAR(MAX)) +
						CAST(ISNULL(MyCols.[is_ansi_padded], '') AS VARCHAR(MAX)) 
						)
			FROM sys.tables MyTables
			INNER JOIN sys.columns MyCols ON MyTables.object_id = MyCols.OBJECT_ID
			INNER JOIN sys.schemas mySchemas ON MyTables.SCHEMA_ID = mySchemas.SCHEMA_ID --AND sys.tables.principal_id = sys.schemas.principal_id
			WHERE mySchemas.name = sys.[schemas].name AND MyTables.name = sys.tables.name
			FOR XML PATH('')
			) tableHash
		FROM sys.tables 
			INNER JOIN sys.schemas ON sys.tables.SCHEMA_ID = sys.schemas.SCHEMA_ID --AND sys.tables.principal_id = sys.schemas.principal_id
		WHERE 
		sys.schemas.name = @Schema AND sys.tables.name = @Table
)

END
GO

--------------------------------------------------------------------------------------------------------------

--Add a function that will return a comma separated list of columns in a table (so we can factor out strconcat())		
IF (SELECT OBJECT_ID('udf_TableColumnList')) IS NULL EXEC('create function udf_TableColumnList (@placeholder int) returns int begin RETURN 1+1 end')
GO
ALTER FUNCTION udf_TableColumnList
	(	@Schema SYSNAME
	,	@Table SYSNAME
	)
	RETURNS VARCHAR(MAX)
AS
BEGIN
--Generate a comma separated list of the columns in the supplied table
RETURN 
	(
	SELECT TOP(1)	STUFF((
				SELECT ', ' + QUOTENAME(MyCols.[name])
				FROM sys.tables MyTables
				INNER JOIN sys.columns MyCols ON MyTables.object_id = MyCols.OBJECT_ID
				INNER JOIN sys.schemas mySchemas ON MyTables.SCHEMA_ID = mySchemas.SCHEMA_ID --AND sys.tables.principal_id = sys.schemas.principal_id
				--WHERE mySchemas.NAME = sys.[schemas].name AND MyTables.NAME = sys.tables.name
				WHERE mySchemas.NAME = @Schema AND MyTables.NAME = @Table
				ORDER BY [MyCols].[column_id]
				FOR XML PATH('')),1,1,'') ColumnList
	)
END
GO

--------------------------------------------------------------------------------------------------------------
--Add a proc to help upgrade deprecated data types in the schema
--------------------------------------------------------------------------------------------------------------
IF OBJECT_ID('FixDeprecatedColumnTypes','P') IS NOT NULL 
    DROP PROC FixDeprecatedColumnTypes
GO 
 
CREATE PROC FixDeprecatedColumnTypes (
@Debug BIT NULL = 1)

AS 
/*
Proc to upgrade our database schema to use nvarchar(max) instead of ntext
mick@sqlfairy.com
http://sqlfairy.com
UPDATE: 2015-10-12 Renamed from FixNTextFields to FixDeprecatedColumnTypes
UPDATE: 2015-10-12 Now updates ntext, text & image types
UPDATE: 2015-10-12 Now updates tables across all schemas
UPDATE: 2015-10-12 Now defaults to debug mode with display of sql but no changes applied.
*/
 
SET NOCOUNT ON 
--DECLARE @Schemaname Sysname = 'dbo' 
DECLARE @ColumnData AS TABLE (
	SCHEMA_NAME		sysname
,	table_name		sysname
,	column_name		sysname 
,	data_type		NVARCHAR(50)
,	processed		INT
,	is_nullable		INT
)

INSERT into @ColumnData 
	SELECT
		sys.schemas.NAME 
	,	sys.tables.NAME 
	,	sys.columns.NAME
	,	sys.systypes.NAME
	,	0
	,	sys.columns.is_nullable

	FROM sys.tables 
		INNER JOIN sys.columns ON sys.tables.object_id = sys.columns.OBJECT_ID
		INNER JOIN sys.schemas ON sys.tables.SCHEMA_ID = sys.schemas.SCHEMA_ID --AND sys.tables.principal_id = sys.schemas.principal_id
		INNER JOIN sys.systypes ON sys.columns.system_type_id = sys.systypes.xTYPE AND sys.columns.system_type_id = sys.systypes.xusertype
	WHERE sys.tables.type = 'U' --AND sys.schemas.NAME = @Schemaname
	AND sys.systypes.NAME IN ('text', 'ntext', 'image')
	AND sys.tables.NAME NOT IN (---- Add exceptions here so we don't process unwanted tables
		'add exceptions here'
	,	'add more exceptions here'
	)----
	
	-----------------
	DECLARE @Sql NVARCHAR(max)
	DECLARE @ProcessTablename SYSNAME 
    DECLARE @ProcessSchemaName SYSNAME 
	DECLARE @ProcessColumnName	sysname
	DECLARE @ProcessData_Type	NVARCHAR(50)
	DECLARE @ProcessIsNullable	INT
 
	WHILE EXISTS (SELECT 1 
					FROM @ColumnData
					WHERE Processed = 0 
					--and SCHEMA_NAME= @Schemaname
				 ) 
         BEGIN 
            --Clear values
			SELECT @ProcessSchemaName	= '' 
            SELECT @ProcessTablename	= '' 
            SELECT @ProcessColumnName	= ''
            SELECT @ProcessData_Type	= ''
            SELECT @ProcessIsNullable	= NULL
            SELECT @Sql					= ''
             
                 
            SELECT TOP 1 
					@ProcessSchemaName = SCHEMA_NAME
                  ,	@ProcessTableName  =  table_name
                  ,	@ProcessColumnName = column_name
                  , @ProcessData_Type = data_type
                  ,	@ProcessIsNullable = is_nullable
                  
            FROM @ColumnData
            WHERE Processed = 0
				
			SET @Sql = 'ALTER TABLE [' + @ProcessSchemaName + '].[' + @ProcessTablename + ']' + CHAR(10)
			SET @Sql += '		ALTER COLUMN ' + @ProcessColumnName + CHAR(10)
			SET @Sql += CASE @ProcessData_Type 
							WHEN 'ntext' THEN '			NVARCHAR(MAX)'
							WHEN 'text'  THEN '			VARCHAR(MAX)'
							WHEN 'image' THEN '         VARBINARY(MAX)'
							ELSE NULL --Intentionally stop this statement from running if we get to this point.
						END 
			SET @Sql += CASE WHEN @ProcessIsNullable = 1 THEN ' NULL' ELSE ' NOT NULL' END + CHAR(10)
			
			IF @debug = 1 
				PRINT @sql 
			
			IF @Debug = 0
				EXEC (@sql)
			
			--Now run an optimisation for each of the columns. 
			--From reading it appears that changing from ntext to nvarchar(max) does not move the first 8k back onto the row. 
			--Updating the column with it's own content apparently fixes this issue. 
			SET @sql = '' --clear our last query
			SET @Sql += 'update [' + @ProcessSchemaName + '].[' + @ProcessTablename + '] set ' + @ProcessColumnName + '=' + @ProcessColumnName + CHAR(10)
			
			IF @debug = 1 
				PRINT @sql 
			
			IF @Debug = 0
				EXEC (@sql) 
					
			UPDATE @ColumnData SET processed = 1 WHERE SCHEMA_NAME = @ProcessSchemaName 
				AND table_name = @ProcessTablename 
				AND column_name = @ProcessColumnName
			
		END	
		
		GO

-----------------------------------------------------------------------------------------------------------------------
--------------------------------ENABLE--DeleteTriggers-------------------------------------------------
--------------------------------ENABLE--DeleteTriggers-------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------

IF (SELECT OBJECT_ID('EnableDeleteTriggers')) IS NULL EXEC('create procedure EnableDeleteTriggers (@placeholder int) as BEGIN SELECT ''THIS IS A PLACEHOLDER'' END')
GO
ALTER PROC EnableDeleteTriggers 
	(
		--@Schemaname Sysname = 'dbo'
		@ArchiveSchemaPrefix NVARCHAR(10) = 'zzzArchive' 
	,	@Debug BIT NULL = 1  --Set this to 0 if you would like apply the changes
	)

AS 
/*
Proc to add delete triggers and archive tables to every table so that we don't ever, ever, ever delete client
data ever, ever, ever again (even if they hit the "yes I understand the implications of deleting all of this data" button :)).
*/

--Okay.  We're going to bail from this procedure if there are any deprecated types in the db which are not supported.
--This includes text, ntext, image types.
--We have a script to convert these but we're not going to run it automagically because liability :)
--Previous experience indicates that it's pretty safe to change these types but this should always be accompanied
--by thorough testing.

IF EXISTS (
			SELECT
				sys.tables.[Name]		tablename
			,	sys.[columns].[Name]	colname
			,	sys.[types].name	typename
			FROM sys.tables
			INNER JOIN sys.[columns]
				ON sys.[tables].[object_id] = sys.[columns].[object_id]
			LEFT OUTER JOIN sys.[types]
				ON sys.[columns].[system_type_id] = sys.[types].[system_type_id]
			WHERE sys.types.name IN ('text','ntext','image')
		) 
	BEGIN
	PRINT CHAR(10)	
	PRINT 'Here be Dragons!!!1!'
	PRINT '_____________________'+ CHAR(10) 
	PRINT 'It appears that this database uses some deprecated types which are incompatible with the delete triggers being installed'
	PRINT 'The text, ntext and image data types have been deprecated by Microsoft and will disappear any second while you''re not looking!'
	PRINT '(or in a future version of SQL Server at least :))' + CHAR(10) + CHAR(10)
	PRINT 'You can run "exec [FixDeprecatedColumnTypes] @Debug = 0" to ATTEMPT TO automatically update these columns.' + CHAR(10)
	PRINT '----------------------------------------------------------------------------------------------'
	PRINT '------------------WARNING----------WARNING----------WARNING----------WARNING------------------'
	PRINT '----------------------------------------------------------------------------------------------' + CHAR(10)
	PRINT 'You should TEST this change thoroughly on your applications.  While it''s quite likely that everything'
	PRINT 'will run fine after the change YOU MUST TEST YOUR APPLICATIONS THOROUGHLY.  The Author of this script'
	PRINT 'bears no responsibility for anything EVER.' + CHAR(10)
	PRINT 'Running "exec [FixDeprecatedColumnTypes]" (in default debug mode) shows the following recommended changes' 
	PRINT '(which you MUST TEST and take full responsibility for) :)' +CHAR(10)
	PRINT '----------------------------------------------------------------------------------------------' + CHAR(10)
	EXEC [FixDeprecatedColumnTypes] @Debug =1

	------------GOODBYE ;)
RETURN
END	

--Print debug comment message
IF @Debug = 1
BEGIN
	PRINT '------------------------------------------------------------------------------------------------'
	PRINT '--The following sql has been generated because you executed EnableDeleteTriggers in debug mode.'
	PRINT '--In this mode the procedure presents the SQL which would be executed if you ran '
	PRINT '--"EXEC EnableDeleteTriggers @Debug=0"'
	PRINT '--This is intended so that you can review the changes that this script will make to your database'
	PRINT '--'
	PRINT '----------------------------------------------------------------------------------------------'
	PRINT '------------------WARNING----------WARNING----------WARNING----------WARNING------------------'
	PRINT '----------------------------------------------------------------------------------------------' 
	PRINT '--You should TEST this change thoroughly outside of production before deploying to ensure'
	PRINT '--that you are comfortable that everything will work as expected in your environment'
	PRINT '--'
	PRINT '--Consider carefully that you may have application state type tables which should be excluded'
	PRINT '--Make sure you read the documenatation that came with this script or refer to '
	PRINT '--http://sqlfairy.com for further info if required.'
	PRINT '--'
	PRINT '--The Author of these scripts bears no responsibility for anything EVER.'
	PRINT '--'
	PRINT '----------------------------------------------------------------------------------------------' + CHAR(10) + CHAR(10)
END 

SET NOCOUNT ON 
DECLARE @tableData AS TABLE (
	SCHEMA_NAME		sysname
,	table_name		sysname
,	trigger_name	sysname NULL
,	columnList		VARCHAR(MAX)  --We will stuff the list of colunns in here
,	processed		int
)

--Create schemas for our delete archive tables.  We're going to create one per schema that contains user tables.
DECLARE @userSchemas as TABLE
			(
				userSchemaId	INT IDENTITY NOT NULL
			,	name			SYSNAME
			,	schema_id		int
			,	principal_id	int
			,	blnProcessed	bit 
			)
	
INSERT INTO @userSchemas 
			(	[name]
			,	[schema_id]
			,	[principal_id]
			,	[blnProcessed]
			)

SELECT DISTINCT
			 	[schemas].[name]
			,	[schemas].[schema_id]
			,	[schemas].[principal_id] 
			,	0
FROM sys.[schemas]
INNER JOIN sys.tables --Only include schemas that have user tables
	ON sys.[schemas].[schema_id] = [sys].[tables].[schema_id]
		AND sys.[tables].type = 'U'
WHERE sys.[schemas].[name] NOT LIKE @ArchiveSchemaPrefix + '%'
	AND schemas.name NOT IN 
		(	'del'
			--Add any others you want to exempt here
		)
		
DECLARE @SchemaToInsert SYSNAME
DECLARE @SchemaSQL NVARCHAR(MAX) = ''

WHILE	(
		SELECT COUNT(userSchemaId) 
		FROM @userSchemas 
		WHERE [@userSchemas].[blnProcessed] IS NULL 
			OR [@userSchemas].[blnProcessed]=0
		) > 0
	BEGIN
    	SELECT TOP 1
		@SchemaToInsert = userSchemas.Name
		FROM @userSchemas userSchemas
		WHERE [userSchemas].[blnProcessed] IS NULL OR [userSchemas].[blnProcessed] = 0
		
		IF (SELECT SCHEMA_ID(@ArchiveSchemaPrefix + @SchemaToInsert)) is NULL
			SET @SchemaSQL += 'CREATE SCHEMA ' + @ArchiveSchemaPrefix + @SchemaToInsert + ' AUTHORIZATION [dbo]' + CHAR(10)

	IF @debug = 0
		BEGIN
			EXEC (@SchemaSQL) --run it now
		END 
	ELSE 
		BEGIN 
			SET @SchemaSQL += 'GO' + CHAR(10)
			PRINT @SchemaSQL
		END 

		SET @SchemaSQL = '' --Ready for the next one...

		UPDATE @userSchemas SET [blnProcessed] = 1 WHERE [@userSchemas].[name] = @SchemaToInsert
    END

	
	
INSERT into @tableData 
	SELECT
		sys.schemas.NAME 
	,	sys.tables.NAME 
	,	sys.triggers.name
	,	[dbo].[udf_TableColumnList]([sys].[schemas].[name], [sys].[tables].[name])
	,	0

	FROM sys.tables 
	INNER JOIN sys.schemas ON sys.tables.SCHEMA_ID = sys.schemas.schema_id
	INNER JOIN @userSchemas userSchemas ON sys.[schemas].[schema_id] = userSchemas.[schema_id] --Apply our filters from further up
	
	---I'm not sure what this is for any more.  We're dropping and re-creating for all anyway.
	LEFT OUTER JOIN sys.triggers ON sys.tables.OBJECT_ID = sys.triggers.parent_id
			AND sys.triggers.NAME like 'DelArchive%' --only show if the table doesn't already have
			 
	WHERE sys.tables.type = 'U' --AND sys.schemas.NAME = @Schemaname
	AND sys.tables.NAME NOT IN 
	(---- Add exceptions here so we don't process unwanted tables
		'Add your excluded table names here'
	,	'And more here...'
	)----
	ORDER BY sys.[schemas].[name], sys.tables.[name]
	
	--SELECT * FROM @tableData ORDER BY 1,2

	DECLARE @Sql NVARCHAR(max)
	DECLARE @ProcessTablename SYSNAME 
    DECLARE @ProcessSchemaName SYSNAME
	DECLARE @ArchiveSchemaName SYSNAME 
	DECLARE @SchemaName SYSNAME

	DECLARE @ColumnList VARCHAR(MAX)
		
	--Generate archive table create/update and trigger drop/recreate SQL
	WHILE EXISTS (
					SELECT 1 
					FROM @tabledata 
					WHERE Processed = 0 
						--AND trigger_name IS NULL
				 ) 
         BEGIN 
           
			SELECT @ProcessSchemaName	= '' 
            SELECT @ProcessTablename	= '' 
            SELECT @Sql					= '' 
                 
            SELECT TOP 1 
					@ProcessSchemaName = QUOTENAME(SCHEMA_NAME)
                  ,	@ProcessTableName  =  QUOTENAME(table_name)
				  , @Schemaname = QUOTENAME(SCHEMA_NAME)
				  ,	@ArchiveSchemaName = QUOTENAME(@ArchiveSchemaPrefix + [@tableData].[SCHEMA_NAME])
				  , @ColumnList = [columnList]
            FROM @tabledata
            WHERE Processed = 0 
				
			
			--PRINT @ColumnList
			--PRINT 'SchemaName= ' + @ProcessSchemaName + ', TableName = ' + @ProcessTablename + ',@Schemaname=' + @Schemaname + ', @ArchiveSchemaName=' + @ArchiveSchemaName + CHAR(10)
								
			SET @Sql += '-----Setup delete trigger on ' + @ProcessSchemaName + '.' + @ProcessTableName + CHAR(10)
			SET @Sql += '--Setup the expected archive table.' + CHAR(10)
			SET @Sql += 'IF  NOT EXISTS (SELECT * FROM dbo.sysobjects WHERE id = OBJECT_ID(''' + @ArchiveSchemaName + '.' + @ProcessTablename + '''))' + CHAR(10)
			SET @Sql += 'BEGIN' + CHAR(10)
			SET @Sql += '		SELECT * INTO ' + @ArchiveSchemaName + '.' + @ProcessTablename + ' FROM ' + @ProcessSchemaName + '.' + @ProcessTablename + ' WHERE 1=0' + CHAR(10)
			SET @Sql += 'END' + CHAR(10)
			SET @Sql += 'ELSE --The archive table already exists so handle the fact that the schema for the table might be different' + CHAR(10)
			SET @Sql += '--Compare the column names and types to determine if we need to rebuild the archive table' + CHAR(10)
			SET @Sql += 'IF (SELECT [dbo].[udf_TableHash](''' + @Schemaname +''', ''' + @ProcessTablename + ''')) <> (SELECT [dbo].[udf_TableHash](''' + @ArchiveSchemaName + ''', ''' + @ProcessTablename + '''))' + CHAR(10)
			SET @Sql += '		BEGIN' + CHAR(10)
			SET @Sql += '		--Archive table needs to be renamed because it''s different from the table it needs to accept updates from' + CHAR(10)
			SET @Sql += '		EXEC sp_rename ''' + @ArchiveSchemaName + '.' + @ProcessTableName + ''', ''' + REPLACE(REPLACE(@ProcessTablename, ']', REPLACE(CAST(CONVERT(VARCHAR(20), GETDATE(), 120)  AS nvarchar(200)), ':', '')), '[','') + ''', ''object''' + CHAR(10)
			SET @Sql += '		--Now Go and re-create the archive table' + CHAR(10)
			SET @Sql += '		SELECT * INTO ' + @ArchiveSchemaName + '.' + @ProcessTablename + ' FROM ' + @ProcessSchemaName + '.' + @ProcessTablename + ' WHERE 1=0' + CHAR(10)
			SET @Sql += '	END' + CHAR(10)
			
			IF @debug = 1 
				PRINT @sql 
			
			IF @Debug = 0
				EXEC (@sql)
						
			SET @sql = ''  --reset for the moment

			SET @Sql += 'IF OBJECT_ID(''' + @Schemaname + '.delArchive'+ REPLACE(REPLACE(@Schemaname + @ProcessTablename,'[',''),']','') + ''',''TR'') IS NOT NULL' + CHAR(10)
			SET @Sql += 'DROP TRIGGER ' + @Schemaname + '.delArchive'+ REPLACE(REPLACE(@Schemaname + @ProcessTablename,'[',''),']','') + CHAR(10)
									
			IF @debug = 0
				BEGIN
					EXEC (@sql) --run it now
				END 
			ELSE 
				BEGIN 
					SET @Sql += 'GO' + CHAR(10)
					PRINT @SQL
				END 
			
						
			SET @sql = '' -- reset it
			SET @Sql += 'CREATE TRIGGER [delArchive' + REPLACE(REPLACE(@Schemaname + @ProcessTablename,'[',''),']','') + '] ON ' + @ProcessSchemaName + '.' + @ProcessTablename + CHAR(10)
			SET @Sql += 'FOR DELETE' + CHAR(10)
			SET @Sql += 'AS' + CHAR(10)
			SET @Sql += 'SET NOCOUNT ON' + CHAR(10)
			SET @Sql += 'IF IDENT_CURRENT (''' + @ArchiveSchemaName + '.' + @ProcessTablename + ''') IS NOT NULL' + CHAR(10)
			SET @Sql += '		SET IDENTITY_INSERT ' + @ArchiveSchemaName + '.' + @ProcessTablename + ' ON'	+ CHAR(10)
			SET @Sql += 'INSERT into ' + @ArchiveSchemaName + '.' + @ProcessTablename + CHAR(10) 
			SET @Sql +=	' (' + CHAR(10) 
			SET @Sql += @ColumnList + CHAR(10)
			SET @Sql +=	' )' + CHAR(10) 
			SET @Sql += 'SELECT '  + CHAR(10)
			SET @Sql += @ColumnList + CHAR(10)
			SET @Sql += 'FROM DELETED' + CHAR(10)-- + 'go' + CHAR(10)
			
			IF @debug = 0
				BEGIN
					EXEC (@sql) --run it now
				END 
			ELSE 
				BEGIN 
					SET @Sql += 'GO' + CHAR(10)
					PRINT @SQL
				END 
			
			SET @sql = ''
		
					
		UPDATE @tableData SET processed = 1 WHERE QUOTENAME(SCHEMA_NAME) = @ProcessSchemaName AND QUOTENAME(table_name) = @ProcessTablename
		
		END	
		
GO

-----------------------------------------------------------------------------------------------
---Need to be able to remove the delete triggers.  EXEC with @debug=0 to apply
-----------------------------------------------------------------------------------------------

IF OBJECT_ID('DisableDeleteTriggers','P') IS NOT NULL 
    DROP PROC DisableDeleteTriggers
GO 
CREATE PROC DisableDeleteTriggers (
@debug BIT NULL = 1)

AS 
/*
Script to remove delete triggers from every table just in case something goes pear shaped
Hopefully we will never need to do this.
*/
SET NOCOUNT ON 

DECLARE @tableData AS TABLE (
	SCHEMA_NAME		sysname
,	table_name		sysname
,	trigger_name	sysname NULL 
,	processed		int
)
	
INSERT into @tableData 
	SELECT
		sys.schemas.NAME 
	,	sys.tables.NAME 
	,	sys.triggers.name
	,	0

	FROM sys.tables 
		INNER JOIN sys.schemas ON sys.tables.SCHEMA_ID = sys.schemas.schema_id                  
		INNER JOIN sys.triggers ON sys.tables.OBJECT_ID = sys.triggers.parent_id
			AND sys.triggers.NAME like 'DelArchive%'
	WHERE sys.tables.type = 'U' 
		
--SELECT * FROM @tableData
	
	DECLARE @Sql NVARCHAR(max) = ''
	DECLARE @ProcessTablename SYSNAME 
    DECLARE @ProcessSchemaName SYSNAME 
	DECLARE @ProcessTriggerName SYSNAME
 
 	WHILE EXISTS 
				(SELECT 1 
					FROM @tabledata 
					WHERE Processed = 0 
				)	
         BEGIN 
           
			SELECT @ProcessSchemaName	= '' 
            SELECT @ProcessTablename	= '' 
            SELECT @ProcessTriggerName = ''
			     
            SELECT TOP 1 
					@ProcessSchemaName = [@tableData].[SCHEMA_NAME]
                  ,	@ProcessTableName  =  [@tableData].[table_name]
				  , @ProcessTriggerName = [@tableData].[trigger_name]
            FROM @tabledata
            WHERE Processed = 0
					
			SET @sql = ''  --reset for the moment
			SET @Sql += 'IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N''[' + @ProcessSchemaName + '].[' + @ProcessTriggerName + ']''))' + CHAR(10)
			SET @Sql += 'DROP TRIGGER [' + @ProcessSchemaName + '].[' + @ProcessTriggerName + ']' + CHAR(10)
			IF @debug = 1 SET @Sql += 'GO' + CHAR(10)
	
			IF @debug = 1 
				PRINT @sql 
			
			IF @Debug = 0
				EXEC (@sql)				
			
	UPDATE @tableData SET processed = 1 WHERE SCHEMA_NAME = @ProcessSchemaName AND table_name = @ProcessTablename
	
	END
			
	--Also remove the optional DDL trigger if present.
	SET @Sql += 'IF (SELECT OBJECT_ID FROM sys.[triggers] WHERE name = ''UpdateDeleteTriggers'' AND [triggers].[parent_class] = 0) IS NOT NULL DROP TRIGGER UpdateDeleteTriggers ON DATABASE'

	IF @debug = 1 
		PRINT @sql 
			
	IF @Debug = 0
		EXEC (@sql)
		
		
GO

--Comment out the following block comment to install a DDL trigger.  This will cause EXEC EnableDeleteTriggers @debug=0 to be fired for 
--each ALTER TABLE or CREATE TABLE statement executed.  USE THIS WITH CAUTION.  YOU MAY FIND THAT THIS INTERFERES WITH PRODUCT UPGRADES!!!
/*
-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL
IF (SELECT OBJECT_ID FROM sys.[triggers] WHERE name = 'UpdateDeleteTriggers' AND [triggers].[parent_class] = 0) IS NOT NULL DROP TRIGGER UpdateDeleteTriggers ON DATABASE
GO
CREATE TRIGGER UpdateDeleteTriggers
ON DATABASE 
FOR ALTER_TABLE, CREATE_TABLE 
AS 
   EXEC dbo.[EnableDeleteTriggers] @debug=0
   PRINT CHAR(10)+ 'Warning!!!' + CHAR(10) + 'dbo.[EnableDeleteTriggers] was executed to ensure that delete archive triggers and tables remain in synch'

--DROP TRIGGER UpdateDeleteTriggers ON DATABASE

-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL-------OPTIONAL
--*/


--Now let's run the stored procedures we just installed (after carefully reading the documenation) :)

--EXEC [FixDeprecatedColumnTypes] --@Debug = 0

--EXEC EnableDeleteTriggers --@debug=0

--EXEC DisableDeleteTriggers --@debug=0


