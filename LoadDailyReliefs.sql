USE [CanvasAdmin]
GO

/****** Object:  StoredProcedure [dbo].[spLoadDailyReliefs]    Script Date: 30/11/2020 10:23:14 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


create procedure [dbo].[spLoadDailyReliefs] (
    @inputXmlFilePath    VARCHAR(MAX)
)
as begin

	/* 
    Daily reliefs information is created in the DailyOrganiser application, and 
    stored in a large XML file (currently ~27MB). It can take a long time to 
    query in certain cases if the queries are not constructed cleverly. 

    Note that Daily Organiser refers to relief teachers as 'emergency' teachers. 

    The key problem is that Daily Organiser stores relief teachers in a separate 
    table to 'normal' teachers. They sometimes have inconsistent StaffId codes. 
    So, they can't be reliably matched to Synergy based on these codes. Also, a teacher
    may appear in both tables with different codes. So {"John Smith", "SMIJO"} in the TEACHERS
    table and {"John Smith", "JS"} in the RELIEFS table. 

    The proposed solution will be to ensure that admin staff update all emails in the 
    relief teacher table to the teacher's Woodcroft email. The email can then be used 
    to match against the Synergy Community table to obtain relief teacher ID etc. 

    I don't think we need to get information for non-relief teachers, because (so far...) the 
    'normal' teachers from the daily reliefs table can be matched to Synergy via their StaffId. 
    It is only the teachers in the emergency teachers table who will have unreliable codes. 
    (This is a good thing because the 'normal' teachers are stored in a different XML file.)
	*/ 


    declare @sql_loadXML NVARCHAR(MAX),
        @XML_all AS XML, 
        @XML_today as XML


    /* ==================================================================== */
    /* Load XML content from Daily Organiser file into table field.         */
    /* ==================================================================== */

    if object_id('tempdb.dbo.##DailyOrg_XML') is not NULL 
        drop table ##DailyOrg_XML

    CREATE TABLE ##DailyOrg_XML (XMLData XML)

    /* Must use dynamic SQL because OPENROWSET won't allow constructed strings. */    
    SET @SQL_loadXML = N'
        INSERT INTO ##DailyOrg_XML(XMLData)
        SELECT 
            CONVERT(XML, BulkColumn) AS BulkColumn
        FROM OPENROWSET(
            BULK ''' + @inputXmlFilePath + ''', 
            SINGLE_BLOB) AS X'

    EXEC sp_executesql @sql_loadXML

    SELECT @XML_all = XMLData FROM ##DailyOrg_XML


    /* ====================================================================== */
    /* EMERGENCY TEACHERS. */
    /* ====================================================================== */


    IF OBJECT_ID('tempdb.dbo.##EmergencyTeachers') is not NULL 
        DROP TABLE ##EmergencyTeachers

    /* Root namespace of the DailyOrganiser file. */
    ;WITH XMLNAMESPACES (DEFAULT 'http://www.timetabling.com.au/DOV9')
    SELECT 
	    DO.EmergencyTeacher.query('FirstName').value('.', 'VARCHAR(200)')  AS FirstName,
	    DO.EmergencyTeacher.query('LastName').value('.', 'VARCHAR(200)')  AS LastName,
	    DO.EmergencyTeacher.query('Email').value('.', 'VARCHAR(500)')  AS Email,
	    DO.EmergencyTeacher.query('Code').value('.', 'VARCHAR(20)')  AS Code
    INTO ##EmergencyTeachers
    FROM @XML_all.nodes('DailyOrganiserData/EmergencyTeachers/EmergencyTeacher') as DO(EmergencyTeacher)
    

    /* ====================================================================== */
    /* DAILY RELIEFS FOR TODAY. */
    /* ====================================================================== */


    /* The XML data for this needs to be queried in a specific manner or
    it will take ~26 minutes to run. The following method only takes a few seconds. */

    /* 1. Use the QUERY XML function to select a sub-branch of the main XML file 
    which contains all data for today only. */ 

    ;WITH XMLNAMESPACES (DEFAULT 'http://www.timetabling.com.au/DOV9')
    SELECT 
        @xml_today = DO.Date.query('.')
    FROM @XML_all.nodes('DailyOrganiserData/Dates/Date') as DO(Date)
    where DO.Date.query('DateString').value('.', 'VARCHAR(20)') = FORMAT(GETDATE(), 'd/MM/yyyy')


    /* 2. Now shred the sub-branch XML to obtain all reliefs for today. */ 

    IF OBJECT_ID('tempdb.dbo.##DailyOrganiserReliefs') is not NULL 
        DROP TABLE ##DailyOrganiserReliefs

    ;WITH XMLNAMESPACES (DEFAULT 'http://www.timetabling.com.au/DOV9')
    select distinct 
        Day.Replacement.query('PeriodCode').value('.', 'VARCHAR(100)') AS Period,
        Day.Replacement.query('ClassCode').value('.', 'VARCHAR(100)') AS ClassCode,
        Day.Replacement.query('ReferenceTeacherCode').value('.', 'VARCHAR(20)') AS AbsentTeacherCode,
        Day.Replacement.query('ReplacementTeacherCode').value('.', 'VARCHAR(20)') AS ReliefTeacherCode
    INTO ##DailyOrganiserReliefs
    from @xml_today.nodes('Date/PeriodReplacements/PeriodReplacement') as Day(Replacement)

    
    /* If the replacement teacher ID cannot be obtained from the STAFF table 
    in Synergy, use the teacher's email address to obtain it from the COMMUNITY 
    table. */

    IF OBJECT_ID('tempdb.dbo.##DailyReliefs') is not NULL 
        DROP TABLE ##DailyReliefs
    
    select 
        DOR.*,
        COM_ABSNT.ID as AbsentTeacherId, 
        COM_ABSNT.Preferred + ' ' + COM_ABSNT.Surname as AbsentTeacherName,
        COM_ABSNT.OccupEmail as AbsentTeacherEmail,
        ISNULL(COM_REL.ID, COM_REL_ET.ID) as ReliefTeacherID, 
        ISNULL(COM_REL.Preferred, COM_REL_ET.Preferred) + ' '  
            + ISNULL(COM_REL.Surname, COM_REL_ET.Surname) as ReliefTeacherName,
        ISNULL(COM_REL.OccupEmail, COM_REL_ET.OccupEmail) as ReliefTeacherEmail 

    into ##DailyReliefs
    from ##DailyOrganiserReliefs as DOR

    -- Absent teacher. 
    left join <SYNERGY_DB>.dbo.Staff as STF_ABSNT
        on DOR.AbsentTeacherCode = STF_ABSNT.SchoolStaffCode 
        and STF_ABSNT.ActiveFlag = 1
    left join <SYNERGY_DB>.dbo.Community as COM_ABSNT
        on STF_ABSNT.ID = COM_ABSNT.ID

    -- Relief: Ordinary Staff
    left join <SYNERGY_DB>.dbo.Staff as STF_REL
        on DOR.ReliefTeacherCode = STF_REL.SchoolStaffCode 
        and STF_REL.ActiveFlag = 1
    left join <SYNERGY_DB>.dbo.Community as COM_REL
        on STF_REL.ID = COM_REL.ID 

    -- Relief: Emergency Teachers Table
    left join ##EmergencyTeachers as ET
        on DOR.ReliefTeacherCode = ET.Code
        and ET.Email like '%@woodcroft.sa.edu.au'
    left join <SYNERGY_DB>.dbo.Community as COM_REL_ET
        on ET.Email = COM_REL_ET.OccupEmail 

    where DOR.ReliefTeacherCode <> '' 
    
    
    /* ==================================================================================================== */
    /* Get list of Canvas course IDs. */ 
    /* ==================================================================================================== */

    /* The Canvas courses that relief teachers are enrolled in are identified by Canvas course IDs, which 
    are based on Synergy class codes, but slightly different. */

    IF OBJECT_ID('tempdb.dbo.##CanvasCourseIds') is not NULL 
        DROP TABLE ##CanvasCourseIds

    create table ##CanvasCourseIds(
        ClassCode       VARCHAR(200), 
        CanvasCourseId  VARCHAR(200))

    /* Canvas course enrollments are supplied through a table-valued function which accepts year & semester 
    as arguments. We have to run the TVF the following way because remote function calls are restricted. */
    DECLARE @sql_executeRemoteFunc NVARCHAR(MAX)
    SET @sql_executeRemoteFunc = N'SELECT DISTINCT ClassCode, CanvasCourseId FROM woodcroft.utfCanvasEnrollments(' 
            + CAST(DATEPART(Year, GETDATE()) AS NVARCHAR(4)) + N', ' 
            + CASE WHEN DATEPART(Month, GETDATE()) <= 6 THEN N'1' ELSE N'2' END + N')';

    insert into ##CanvasCourseIds(
        ClassCode, 
        CanvasCourseId)
    EXEC <SYNERGY_DB>..sp_executesql @Sql_executeRemoteFunc
    

    /* ==================================================================================================== */
    /* Update Daily Reliefs table with today's information. */ 
    /* ==================================================================================================== */


    insert into dbo.DailyReliefs (
        Period, 
        ClassCode,
        CanvasCourseId,
        AbsentTeacherCode, 
        AbsentTeacherId,
        AbsentTeacherName, 
        AbsentTeacherEmail,
        ReliefTeacherCode, 
        ReliefTeacherId,
        ReliefTeacherName, 
        ReliefTeacherEmail,
        DateModified)
    select 
        DR.Period, 
        DR.ClassCode,
        CCID.CanvasCourseId,
        DR.AbsentTeacherCode, 
        DR.AbsentTeacherId,
        DR.AbsentTeacherName, 
        DR.AbsentTeacherEmail,
        DR.ReliefTeacherCode, 
        DR.ReliefTeacherId,
        DR.ReliefTeacherName, 
        DR.ReliefTeacherEmail,
        GETDATE() AS DateModified
    from ##DailyReliefs as DR
    left join ##CanvasCourseIds as CCID
        on DR.ClassCode = CCID.ClassCode collate Latin1_General_CI_AI


    /* ==================================================================================================== */
    /* Cleanup daily reliefs table - remove old records. */ 
    /* ==================================================================================================== */


    DELETE FROM 
        dbo.DailyReliefs
    WHERE DATEDIFF(Day, DateModified, GETDATE()) >= 365


    /* ==================================================================================================== */
    /* Update the Daily Reliefs email log. */ 
    /* ==================================================================================================== */

    EXEC dbo.spiUpdateDailyReliefsEmailLog

END

GO


