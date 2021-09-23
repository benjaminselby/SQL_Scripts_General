USE [Synergetic_AUSA_WOODCROFT_PRD]
GO

/****** Object:  StoredProcedure [dbo].[uspiOnlineImportApplicationCustomNodes]    Script Date: 21/09/2021 11:02:20 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


ALTER PROCEDURE [dbo].[uspiOnlineImportApplicationCustomNodes] 
  @OnlineImportApplicationsSeq INTEGER = 0

AS  
SET NOCOUNT ON
/* 
HISTORY
================================================================================

16/11/2011 AGM15465 

    Created.

    This is the template used for accessing Custom data in the Online 
    Import Application XML. This script needs amending to process 
    the custom data as is required. The #CustomNodes table structure 
    contains the information contained in the custom nodes
    at Application level, Contact level and Student level 
    this is referred to as the NodeType.

03/04/12 YS17538

    Set this to create only so it doesnt overwrite client copy
    
16/05/12 YS17889

    Added OnlineImportApplicationsSeq

2021/09/16 selby_b@woodcroft.sa.edu.au

    New code added implementing Custom Fields to enable additional information 
    to be inserted into Future Students and associated tables via the 
    Future Students Online Import. 

    - Medicare Number added to Custom Fields.

*/

    CREATE TABLE #CustomNodes
    (
      NodeType VARCHAR(50),
      FieldName VARCHAR(100),
      FieldData VARCHAR(MAX),
      StudentGiven1 VARCHAR(50),
      StudentSurname VARCHAR(100),
      StudentBirthdate VARCHAR(10),
      OnlineImportApplicationsSeq INT
    )
    INSERT INTO #CustomNodes
    EXEC dbo.spsOnlineImportApplicationCustomNodes 
        @OnlineImportApplicationsSeq = @OnlineImportApplicationsSeq
    

    /* ====================================================================== */
    /* Custom code below. */
    /* ====================================================================== */



    /* ====================== FUTURE STUDENT MEDICARE NUMBER ====================== */

    DECLARE @FutureStudentId INT = (
        select FutureID
        from dbo.OnlineImportStudents
        where OnlineImportApplicationsSeq = @OnlineImportApplicationsSeq)

    DECLARE @MedicareNumber varchar(20) = (
        SELECT FieldData
        FROM  #CustomNodes
        WHERE FieldName = 'MedicareNumber')

    /* If this student's medical record already exists, update it. 
    Otherwise create a new record. */ 

    IF EXISTS(
        SELECT 1
        FROM dbo.MedicalDetails 
        WHERE ID = + CAST(@FutureStudentId as varchar(20))) 
    BEGIN 

        UPDATE dbo.MedicalDetails 
        SET MedicareNo = @MedicareNumber
        WHERE ID = CAST(@FutureStudentId as varchar(20))

    END 
    ELSE BEGIN 

        INSERT INTO dbo.MedicalDetails (ID, MedicareNo)
        VALUES (
            CAST(@FutureStudentId as varchar(20)),
            @MedicareNumber)

    END
   
    /* Uncomment for debugging. */
    /*
    insert into woodcroft.uMessageLog(Application, Key1, Key2, Message)
    values (
        'Synergetic',
        'OnlineApplicationImports',
        'Debug',
        @UpdateSql)
    */
    

    /* ====================================================================== */
    /* Custom code END. */
    /* ====================================================================== */


    DROP TABLE #CustomNodes

GO


