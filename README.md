# MagicUndeleteForSQLServer
Stop deleting your customer's data.  

For detailed information on this script please visit http://www.sqlfairy.com.au/teh-sql-fairy-blog/

The following scripts written by mick@sqlfairy.com.au http://sqlfairy.com.au are intended to assist
primarily with cases where you need to support an applicaton which does not archive or flag it's deletes 
from the database.  

Many applications follow a pattern whereby user content is never really deleted from the application 
database; rather the deleted rows are flagged as deleted (with a deleted date or other indication) 
and the application is designed around this principle only ever returning rows which aren't "deleted".  

Some other (particularly older though not necessarily) applications have been encountered which do not 
follow this pattern.  Once the end user deletes something (often after clicking through several dialogs
confirming that they fully comprehend the dire ramifications of their actions) the application will
go ahead and delete the row.  Often re-factoring such applications to perform "soft" deletes is not
practical and Support, Operations, DBA, Management etc all need to scurry around restoring backups and 
selectively performing cross database queries to get back the tremendously important data that the user 
(or worse an application error) has excised.  

If you're lucky enough to support such an application you may find these scripts of tremendous benefit.
The scripts form a system which automatically applies after delete triggers to all of the user tables 
(with configurable exceptions) which copy deleted rows to a backup copy of the table.  The scripts
(stored procedures) look after creating the backup schemas/tables and also look after keeping the
triggers up to date and in synch either automatically via a DDL trigger or manually by re-executing
following an upgrade.

The original version of these scripts was written in 2012 and have been in production use since.  
This version (below) has been re-factored to support more widespread use than the original requirements might 
accomodate.  The design of the triggers themselves has not changed in this version.  See the revision list below 
for a list of recent changes.

What gets installed and what's it for?  

------------------------------
Function: udf_TableHash

Description: 
Support function used to compare two tables so that we know if we need to rename and re-create the 
Archive tables containing the deleted rows archive

Params: 
@Schema is the schema of the table
@Table is tne name of the table

Returns:
VARCHAR(MAX) like 'qLkzrCoJsTs+cGafPj+02w==4lsF0HZKRoO5UtpLDHlHZw==Pw81e3zaHGnvrcjdpCwwtA==MiIj0ex3xYEoVnSlLuCEcA==uYtAonXLPcHIF+boFDd4bw==BG8f/Ho1zsk88gb/czFOBA==rr2bRwyc2WzS96qcI6RRJw==XKVtD1kNgH9i/B/SvzjpHw==tGXhQlZHNwAczJyJcPt4cw==WwGxHcdZJQiP6eRhqri++Q==Bg8LO8C5QCOeLTOJQDMKhg==LlLq0H1zErbUhnVQju2Hmw==M/DQboDGATM7mebOQEGi1A=='

Example usage:

declare @myTableHash varchar(max)
set @myTableHash = (select dbo.udf_TableHash('Person','Person'))
select @myTableHash myHashVal

------------------------------

Function: udf_TableColumnList

Description:
Support function used to generate the column names in triggers. Columns are returned in column order separated by commas

Params: 
@Schema is the schema of the table
@Table is tne name of the table

Returns:
VARCHAR(MAX) like '[BusinessEntityID], [PersonType], [NameStyle], [Title], [FirstName], [MiddleName], [LastName], [Suffix], [EmailPromotion], [AdditionalContactInfo], [Demographics], [rowguid], [ModifiedDate]'

Example usage:

declare @myTableCols varchar(max)
set @myTableCols = (select dbo.udf_TableColumnList('Person','Person'))
select @myTableCols myColList

--------------------------------
Procedure: FixDeprecatedColumnTypes

Description: Stored procedure to upgrade deprecated column types TEXT, NTEXT and IMAGE to VARCHAR(MAX), NVARCHAR(MAX) and VARBINARY(MAX) respectively.
The default mode of this stored procedure is to run in debug which does not apply any changes.  In debug mode the proc will return the SQL which would
upgrade your database to use the non deprecated types.  IT IS UP TO YOU TO CONFIRM THAT THIS IS AN APPROPRIATE COURSE OF ACTION.

Upgrading these types is necessary because triggers (and presumably OUTPUT) cannot access these types and they are not included in the INSERTED and DELETED 
tables (and therefore cannot be backed up by a trigger).  You do not need to execute this procedure unless advised to do so as a result of executing EnableDeleteTriggers.
EnableDeleteTriggers checks to see if there are any offending columns in the database and will execute FixDeprecatedColumnTypes in Debug mode to notify you
of the changes required.  EnableDeleteTriggers will not continue until TEXT, NTEXT and IMAGE types have been removed/upgraded from the database.

Params: @Debug BIT (optional. Defaults to 1.  You will need to specify @Debug=0 to have FixDeprecatedColumnTypes make any changes)

Returns:
With @Debug=1 outputs sql statements to the "Messages" window for your review.  With @Debug=0 executes these statements.

Example output:

----
	ALTER TABLE [MyTestSchema].[myTestTable01]
			ALTER COLUMN mybadtextcol4
				VARCHAR(MAX) NULL

	update [MyTestSchema].[myTestTable01] set mybadtextcol4=mybadtextcol4

	ALTER TABLE [MyTestSchema].[myTestTable01]
			ALTER COLUMN mybadntextcol4
				NVARCHAR(MAX) NULL

	update [MyTestSchema].[myTestTable01] set mybadntextcol4=mybadntextcol4

	ALTER TABLE [MyTestSchema].[myTestTable01]
			ALTER COLUMN mybadimagecol4
				VARBINARY(MAX) NULL

	update [MyTestSchema].[myTestTable01] set mybadimagecol4=mybadimagecol4
----

NB: The update in the script above which is copying the altered columns to themselves is an optimisation.  An improvement of the (MAX) types over
	the deprecated ones is that the (MAX) types store the first 8000 bytes on the row.  Data is only stored to a blob if it exceeds 8000 bytes. Performing
	this optimisation moves the first 8000 bytes back to the row.

--------------------------------
Procedure: EnableDeleteTriggers

Description:

This is the procedure which looks after adding archive tables and corresponding delete tables to a database.  It performs the following actions:

NB: By default EnableDeleteTriggers executes in Debug mode providing SQL output to the Messages window rather than making any changes to the database.  You
MUST review this output before applying the changes.  The Author takes all care adn no responsibility :)

* Check to see if there are unsuported data types in the database.  If so aborts after providing some information about actions required to resolve the issue

* Adds additional schemas if required to contain the archive tables.  An additional schema will be created for each of the existing schemas (containing user
	tables) that exists in your database.  The default format of the schema created is "zzzArchiveSchemaName" where SchemaName is the name of your schema(s)
	You are able to override the default archive schema name by specifyging the @ArchiveSchemaPrefix parameter.  Note that if you do override this default
	you should be painstakingly careful to always use your selected choice or you'll create an awful mess :).
	The default schema prefix was selected so that when viewing tables in SSMS the archive tables sort together at the bottom of the list.

*	Creates a copy of each table (not excluded tables and not the archive tables themselves. :)) in the corresponding archive schema with the same name.  
	If a copy of the table already exists in the archive schema the tables/columns are compared.  If they are found to be different then the archive table
	is renamed by appending the current date and time e.g. 'AddressType2015-10-12 194018' and a new copy of the table is made.

*	All existing delete archive triggers are dropped and re-created.  Trigger names must be unique within a schema.  The naming convention is
	"delArchiveSchemaNameTableName" so the trigger for the [Sales].[SalesOrderHeader] table will be "delArchiveSalesSalesOrderHeader"
	
	Generated triggers look like this:

		GO
		CREATE TRIGGER [Sales].[delArchiveSalesSalesOrderHeader] ON [Sales].[SalesOrderHeader]
		FOR DELETE
		AS
		SET NOCOUNT ON
		IF IDENT_CURRENT ('[zzzArchiveSales].[SalesOrderHeader]') IS NOT NULL
				SET IDENTITY_INSERT [zzzArchiveSales].[SalesOrderHeader] ON
		INSERT into [zzzArchiveSales].[SalesOrderHeader]
		 (
		 [SalesOrderID], [RevisionNumber], [OrderDate], [DueDate], [ShipDate], [Status], [OnlineOrderFlag], [SalesOrderNumber], [PurchaseOrderNumber], [AccountNumber], [CustomerID], [SalesPersonID], [TerritoryID], [BillToAddressID], [ShipToAddressID], [ShipMethodID], [CreditCardID], [CreditCardApprovalCode], [CurrencyRateID], [SubTotal], [TaxAmt], [Freight], [TotalDue], [Comment], [rowguid], [ModifiedDate]
		 )
		SELECT 
		 [SalesOrderID], [RevisionNumber], [OrderDate], [DueDate], [ShipDate], [Status], [OnlineOrderFlag], [SalesOrderNumber], [PurchaseOrderNumber], [AccountNumber], [CustomerID], [SalesPersonID], [TerritoryID], [BillToAddressID], [ShipToAddressID], [ShipMethodID], [CreditCardID], [CreditCardApprovalCode], [CurrencyRateID], [SubTotal], [TaxAmt], [Freight], [TotalDue], [Comment], [rowguid], [ModifiedDate]
		FROM DELETED


-----------------------------------------------------------------------------------------------------------------------------------------------------------
IMPORTANT:
Exclusions for Schemas and Tables can be made by altering the EnableDeleteTriggers Procedure to add them to the exclusion list. 
Searching for "exclusion" should show you the relevant locations.  It's likely that your database/application has some tables which 
require regular deletion of transitory state records e.g. sessions, import staging.  
It might be a critical performance and size consideration that you carefully identify and exclude these tables!!!

After enabling delete triggers it is recommended that you carefully monitor the growth of the archive tables.  Watch out for that special end of month
processing :)
-----------------------------------------------------------------------------------------------------------------------------------------------------------

Returns:
With @Debug=1 outputs sql statements to the "Messages" window for your review.  With @Debug=0 executes these statements.

Example output: 
(Just one table's worth.  The trigger code is repeated for every table in the database)
----
------------------------------------------------------------------------------------------------
--The following sql has been generated because you executed EnableDeleteTriggers in debug mode.
--In this mode the script generates the SQL which would be executed if you ran "EXEC EnableDeleteTriggers @Debug=0"
--
--This is intended so that you can review the changes that this script will make to your database
--
----------------------------------------------------------------------------------------------
------------------WARNING----------WARNING----------WARNING----------WARNING------------------
----------------------------------------------------------------------------------------------
--You should TEST this change thoroughly outside of production before deploying to ensure
--that you are comfortable that everything will work as expected in your environment
--
--The Author of these scripts bears no responsibility for anything EVER.
----------------------------------------------------------------------------------------------

CREATE SCHEMA zzzArchivedbo AUTHORIZATION [dbo]
CREATE SCHEMA zzzArchiveHumanResources AUTHORIZATION [dbo]
CREATE SCHEMA zzzArchivePerson AUTHORIZATION [dbo]
CREATE SCHEMA zzzArchiveProduction AUTHORIZATION [dbo]
CREATE SCHEMA zzzArchivePurchasing AUTHORIZATION [dbo]
CREATE SCHEMA zzzArchiveSales AUTHORIZATION [dbo]
GO

-----Setup delete trigger on [Sales].[SalesOrderHeader]
--Setup the expected archive table.  Set identity insert off if relevant
IF  NOT EXISTS (SELECT * FROM dbo.sysobjects WHERE id = OBJECT_ID('[zzzArchiveSales].[SalesOrderHeader]'))
BEGIN
		SELECT * INTO [zzzArchiveSales].[SalesOrderHeader] FROM [Sales].[SalesOrderHeader] WHERE 1=0
END
ELSE --The archive table already exists so handle the fact that the schema for the table might be different
--Compare the column names and types to determine if we need to rebuild the archive table
IF (SELECT [dbo].[udf_TableHash]('[Sales]', '[SalesOrderHeader]')) <> (SELECT [dbo].[udf_TableHash]('[zzzArchiveSales]', '[SalesOrderHeader]'))
		BEGIN
		--Archive table needs to be renamed because it's different from the table it needs to accept updates from
		EXEC sp_rename '[zzzArchiveSales].[SalesOrderHeader]', 'SalesOrderHeader2015-10-13 022609', 'object'
		--Now Go and re-create the archive table
		SELECT * INTO [zzzArchiveSales].[SalesOrderHeader] FROM [Sales].[SalesOrderHeader] WHERE 1=0
	END

IF OBJECT_ID('[Sales].delArchiveSalesSalesOrderHeader','TR') IS NOT NULL
DROP TRIGGER [Sales].delArchiveSalesSalesOrderHeader
GO

CREATE TRIGGER [delArchiveSalesSalesOrderHeader] ON [Sales].[SalesOrderHeader]
FOR DELETE
AS
SET NOCOUNT ON
IF IDENT_CURRENT ('[zzzArchiveSales].[SalesOrderHeader]') IS NOT NULL
		SET IDENTITY_INSERT [zzzArchiveSales].[SalesOrderHeader] ON
INSERT into [zzzArchiveSales].[SalesOrderHeader]
 (
 [SalesOrderID], [RevisionNumber], [OrderDate], [DueDate], [ShipDate], [Status], [OnlineOrderFlag], [SalesOrderNumber], [PurchaseOrderNumber], [AccountNumber], [CustomerID], [SalesPersonID], [TerritoryID], [BillToAddressID], [ShipToAddressID], [ShipMethodID], [CreditCardID], [CreditCardApprovalCode], [CurrencyRateID], [SubTotal], [TaxAmt], [Freight], [TotalDue], [Comment], [rowguid], [ModifiedDate]
 )
SELECT 
 [SalesOrderID], [RevisionNumber], [OrderDate], [DueDate], [ShipDate], [Status], [OnlineOrderFlag], [SalesOrderNumber], [PurchaseOrderNumber], [AccountNumber], [CustomerID], [SalesPersonID], [TerritoryID], [BillToAddressID], [ShipToAddressID], [ShipMethodID], [CreditCardID], [CreditCardApprovalCode], [CurrencyRateID], [SubTotal], [TaxAmt], [Freight], [TotalDue], [Comment], [rowguid], [ModifiedDate]
FROM DELETED
GO

----

--------------------------------
Procedure: DisableDeleteTriggers

Description: Deletes all triggers in the database like 'DelArchive%'.  Also deletes UpdateDeleteTriggers DDL trigger if present.

Params: @Debug BIT (optional. Defaults to 1.  You will need to specify @Debug=0 to drop the triggers)

Returns:
With @Debug=1 outputs sql statements to the "Messages" window for your review.  With @Debug=0 executes these statements.

Example output:

----
IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'[Sales].[delArchiveSalesSpecialOffer]'))
DROP TRIGGER [Sales].[delArchiveSalesSpecialOffer]
GO

IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'[Sales].[delArchiveSalesSpecialOfferProduct]'))
DROP TRIGGER [Sales].[delArchiveSalesSpecialOfferProduct]
GO

IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'[Sales].[delArchiveSalesStore]'))
DROP TRIGGER [Sales].[delArchiveSalesStore]
GO

IF  EXISTS (SELECT * FROM sys.triggers WHERE object_id = OBJECT_ID(N'[Sales].[delArchiveSalesStore]'))
DROP TRIGGER [Sales].[delArchiveSalesStore]
GO
IF (SELECT OBJECT_ID FROM sys.[triggers] WHERE name = 'UpdateDeleteTriggers' AND [triggers].[parent_class] = 0) IS NOT NULL DROP TRIGGER UpdateDeleteTriggers ON DATABASE
----

*/

----------CHANGE HISTORY-----------

--Original description --29-10-2012----Version 1.0
--Script to fix ntext columns in the database (convert them to nvarchar(max) 
--and to install for delete triggers on every table (with some exceptions)
--
--The ntext change is primarily because for delete triggers can't handle data in ntext and text
--
--The process also adds a del schema and creates a replica of every table within this namespace
--If the del.table already exists it will be compared to the dbo.table version to determine if the
--columns are different (different list of column names and data type) 
--and will rename the existing del.table to del.table.dateTime and re-create the del.table table
--based on the current dbo.table schema
--
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

*/
	
--------------------------------------------------------------------------------------------------------------
