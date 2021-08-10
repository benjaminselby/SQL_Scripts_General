USE [CanvasAdmin]
GO

/****** Object:  StoredProcedure [dbo].[spLoadDailyReliefs]    Script Date: 10/08/2021 11:18:19 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE procedure [dbo].[spLoadDailyReliefs] (
    @inputXmlFilePath    VARCHAR(MAX)
) AS 

BEGIN TRY

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

    I don't think we need to get information for non-relief teachers, because (hopefully...) the 
    'normal' teachers from the daily reliefs table can be matched to Synergy via their StaffId. 
    It is only the teachers in the emergency teachers table who will have unreliable codes. 
    (This is a good thing because the 'normal' teachers are stored in a different XML file.)
    */ 


    declare @sql_loadXML    NVARCHAR(MAX)
    declare @XML_all        XML
    declare @XML_today      XML


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
    it will take ~26 minutes to run. */

    /* Use the QUERY XML function to select a sub-branch of the main XML file 
    which contains all data for today only. */ 

    ;WITH XMLNAMESPACES (DEFAULT 'http://www.timetabling.com.au/DOV9')
    SELECT 
        @xml_today = DO.Date.query('.')
    FROM @XML_all.nodes('DailyOrganiserData/Dates/Date') as DO(Date)
    where DO.Date.query('DateString').value('.', 'VARCHAR(20)') = FORMAT(GETDATE(), 'd/MM/yyyy')


    /* Now shred the sub-branch XML to obtain all reliefs for today. */ 

    IF OBJECT_ID('tempdb.dbo.##DailyOrganiserReliefs') is not NULL 
        DROP TABLE ##DailyOrganiserReliefs

    ;WITH XMLNAMESPACES (DEFAULT 'http://www.timetabling.com.au/DOV9')
    select distinct 
        Day.Replacement.query('PeriodCode').value('.', 'VARCHAR(100)') AS Period,
        -- Synergy truncates long class codes to only 15 characters, so we need to match that. 
        SUBSTRING(Day.Replacement.query('ClassCode').value('.', 'VARCHAR(100)'), 1, 15) AS ClassCode,    
        Day.Replacement.query('ReferenceTeacherCode').value('.', 'VARCHAR(20)') AS AbsentTeacherCode,
        Day.Replacement.query('ReplacementTeacherCode').value('.', 'VARCHAR(20)') AS ReliefTeacherCode
    INTO ##DailyOrganiserReliefs
    from @xml_today.nodes('Date/PeriodReplacements/PeriodReplacement') as Day(Replacement)


    /* [2021.06.16 SELBY_B]

    We've recently started seeing problems where reliefs are being saved to the 
    Daily Organiser XML file where there are no actual classes for that relief on 
    the corresponding day. What we do here is to DELETE any entries from today's 
    Daily Organiser relief classes if we cannot find a match in the Synergy timetable 
    for a given Class Code on the current day at a matching period. This seems to clear 
    up the vast majority of erroneous records. */

    DELETE DOR
    FROM ##DailyOrganiserReliefs as DOR
    left join Synergy.Synergetic_AUSA_WOODCROFT_PRD.dbo.Timetable as TT
        on TT.FileYear = datepart(year, getdate())
        and TT.FileSemester = case when datepart(month, getdate()) <= 6 then 1 else 2 end
        and TT.DayNumber = datepart(weekday, getdate()) - 1
        and DOR.ClassCode = TT.ClassCode 
        /* Tutor Group period is marked as 'TG' in the Daily Organiser data, but 
        it is Period 1 in Synergy. All other periods are offset by -1 as a result. */
        and DOR.Period = case   
            when TT.PeriodNumber = 1 then 'TG'
            else CAST(TT.PeriodNumber - 1 as VARCHAR(2)) end
    WHERE TT.ClassCode is NULL
        

    /* ====================================================================== */
    /* ATTACH STAFF INFORMATION. */
    /* ====================================================================== */

    
    /* If the replacement teacher ID cannot be obtained from the STAFF table 
    in Synergy, use the teacher's email address to obtain it from the COMMUNITY 
    table. */

    IF OBJECT_ID('tempdb.dbo.##StaffInformation') is not NULL 
        DROP TABLE ##StaffInformation
    
    select 
        DOR.*,
        COM_ABSNT.ID as AbsentTeacherId, 
        COM_ABSNT.Preferred + ' ' + COM_ABSNT.Surname as AbsentTeacherName,
        COM_ABSNT.OccupEmail as AbsentTeacherEmail,
        ISNULL(COM_REL.ID, COM_REL_ET.ID) as ReliefTeacherID, 
        ISNULL(COM_REL.Preferred, COM_REL_ET.Preferred) + ' '  
            + ISNULL(COM_REL.Surname, COM_REL_ET.Surname) as ReliefTeacherName,
        ISNULL(COM_REL.OccupEmail, COM_REL_ET.OccupEmail) as ReliefTeacherEmail 

    into ##StaffInformation
    from ##DailyOrganiserReliefs as DOR

    -- Absent teacher. 
    left join Synergy.Synergetic_AUSA_WOODCROFT_PRD.dbo.Staff as STF_ABSNT
        on DOR.AbsentTeacherCode = STF_ABSNT.SchoolStaffCode 
        and STF_ABSNT.ActiveFlag = 1
    left join Synergy.Synergetic_AUSA_WOODCROFT_PRD.dbo.Community as COM_ABSNT
        on STF_ABSNT.ID = COM_ABSNT.ID

    -- Relief: Ordinary Staff
    left join Synergy.Synergetic_AUSA_WOODCROFT_PRD.dbo.Staff as STF_REL
        on DOR.ReliefTeacherCode = STF_REL.SchoolStaffCode 
        and STF_REL.ActiveFlag = 1
    left join Synergy.Synergetic_AUSA_WOODCROFT_PRD.dbo.Community as COM_REL
        on STF_REL.ID = COM_REL.ID 

    -- Relief: Emergency Teachers Table
    left join ##EmergencyTeachers as ET
        on DOR.ReliefTeacherCode = ET.Code
        and ET.Email like '%@woodcroft.sa.edu.au'
    left join Synergy.Synergetic_AUSA_WOODCROFT_PRD.dbo.Community as COM_REL_ET
        on ET.Email = COM_REL_ET.OccupEmail 

    where DOR.ReliefTeacherCode <> '' 
    

    /* ====================================================================== */
    /* ADD SIMULTANEOUS CLASSES FROM SYNERGY TIMETABLE. */
    /* ====================================================================== */

    /* 
    Some staff are booked for multiple classes in Synergy, but the classes are held 
    at the same time and location. Ordinarily, these 'Composite Classes' can have 
    the same relief member assigned to both. However, sometimes multiple classes are 
    scheduled for the same staff member but are NOT listed as Composite Classes in Timetabler. 
    These extra classes will not appear in the Reliefs data from Daily Organiser. 
    We add these extra classes here from the Synergy timetable. 
    */
    
    IF OBJECT_ID('tempdb.dbo.##DailyReliefs') is not NULL 
        DROP TABLE ##DailyReliefs
        
    select 
        SINF.Period, 
        SINF.ClassCode, 
        SINF.AbsentTeacherCode,
        SINF.ReliefTeacherCode,
        SINF.AbsentTeacherId,
        SINF.AbsentTeacherName,
        SINF.AbsentTeacherEmail,
        SINF.ReliefTeacherID,
        SINF.ReliefTeacherName,
        SINF.ReliefTeacherEmail
    into ##DailyReliefs
    from ##StaffInformation as SINF

    union

    select 
        SINF.Period, 
        TT.ClassCode, -- Composite class code, 
        SINF.AbsentTeacherCode,
        SINF.ReliefTeacherCode,
        SINF.AbsentTeacherId,
        SINF.AbsentTeacherName,
        SINF.AbsentTeacherEmail,
        SINF.ReliefTeacherID,
        SINF.ReliefTeacherName,
        SINF.ReliefTeacherEmail
    from ##StaffInformation as SINF
    inner join Synergy.Synergetic_AUSA_WOODCROFT_PRD.dbo.Timetable as TT
    on
        TT.FileYear = DATEPART(YEAR, GETDATE())
        AND TT.FileSemester = CASE WHEN DATEPART(MONTH, GETDATE()) <= 6 THEN 1 ELSE 2 END
        AND TT.DayNumber = DATEPART(WEEKDAY, GETDATE()) - 1
        and SINF.Period = case   
            when TT.PeriodNumber = 1 then 'TG'
            else CAST(TT.PeriodNumber - 1 as VARCHAR(2)) end
        and SINF.AbsentTeacherId = TT.StaffId
        and SINF.ClassCode <> TT.ClassCode

    
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
    EXEC Synergy.Synergetic_AUSA_WOODCROFT_PRD..sp_executesql @Sql_executeRemoteFunc
    

    /* ==================================================================================================== */
    /* Update Daily Reliefs table with today's information. */ 
    /* ==================================================================================================== */


    insert into dbo.DailyReliefs (
        ReliefDate,
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
        CAST(GETDATE() AS DATE),
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
    where DR.ReliefTeacherID is not NULL 
        and DR.ReliefTeacherEmail is not NULL
        and DR.ReliefTeacherName is not NULL


    /* ==================================================================================================== */
    /* Cleanup daily reliefs table - remove old records. */ 
    /* ==================================================================================================== */


    DELETE FROM 
        dbo.DailyReliefs
    WHERE DATEDIFF(Day, ReliefDate, GETDATE()) >= 365


    /* ==================================================================================================== */
    /* Update the Daily Reliefs email log. */ 
    /* ==================================================================================================== */

    EXEC dbo.spiUpdateDailyReliefsEmailLog

    select 0 as Error
    return


END TRY
BEGIN CATCH

    INSERT INTO dbo.ErrorLog
    VALUES
        (SUSER_SNAME(),
        ERROR_NUMBER(),
        ERROR_STATE(),
        ERROR_SEVERITY(),
        ERROR_LINE(),
        ERROR_PROCEDURE(),
        ERROR_MESSAGE(),
        GETDATE());

    select 1 as Error
    return

END CATCH


GO


