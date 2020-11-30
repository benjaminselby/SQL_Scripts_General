USE [Synergetic_AUSA_WOODCROFT_PRD]
GO

/****** Object:  UserDefinedFunction [woodcroft].[utfCanvasEnrollments]    Script Date: 30/11/2020 10:45:38 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE FUNCTION [woodcroft].[utfCanvasEnrollments](
    @Year VARCHAR(4), 
    @Semester VARCHAR(1))
RETURNS @enrollments TABLE (
    FileYear                INT,
    FileSemester            TINYINT,
    UserId                  INT, 
    Email                   VARCHAR(999), 
    FirstName               VARCHAR(999), 
    PreferredName           VARCHAR(999), 
    LastName                VARCHAR(999),
    UserStatus              VARCHAR(100),
    Role                    VARCHAR(100), 
    ClassCode               VARCHAR(200),
    ClassDescription        VARCHAR(MAX),
    ClassNormalYearLevel    INT,
    StopDate                DATE,
    LearningAreaCode        VARCHAR(10),
    CanvasCourseId          VARCHAR(200),
    CourseSection           VARCHAR(200),
    CanvasTerm              VARCHAR(100),
    EnrollmentStatus        VARCHAR(100))
AS BEGIN

    /*
    AUTHOR: Benjamin Selby
    DATE:   07.2020
    NOTES: 
        - Returns a table of all Canvas enrollments for the specified year and semester, including the Canvas 
            course code information etc. required for the SIS upload CSVs. 
    DEPENDENCIES: 
        - woodcroft.uCanvasFullYearCourses (Table): Classes which run for the full year, and hence their TERM values 
            and COURSE_ID values should be slightly different in Canvas. 
        - woodcroft.uCanvasExcludedCourses (Table): Classes which do not have Canvas courses. 
    */

    DECLARE 
        @Year2dgt VARCHAR(2),
        @Year4dgt VARCHAR(4)

    SET @Year2dgt = SUBSTRING(@Year, LEN(@Year) - 1, 2)
    SET @Year4dgt = @Year 


    INSERT INTO @enrollments (
        FileYear,
        FileSemester,
        UserId,
        Email,
        FirstName,
        PreferredName,
        LastName,
        UserStatus,
        Role,
        ClassCode,
        ClassDescription,
        ClassNormalYearLevel,
        StopDate,
        LearningAreaCode,
        EnrollmentStatus,
        CanvasCourseId,
        CourseSection,
        CanvasTerm)

    SELECT 
        ENROL.FileYear,
        ENROL.FileSemester, 
        ENROL.UserId,
        ENROL.Email,
        ENROL.FirstName,
        ENROL.PreferredName,
        ENROL.LastName,
        ENROL.UserStatus, 
        ENROL.Role,
        ENROL.ClassCode,
        ENROL.ClassDescription,
        ENROL.ClassNormalYearLevel,
        ENROL.StopDate,
        ENROL.LearningAreaCode,
        ENROL.EnrollmentStatus,

        CASE 
            /* Special cases. */ 
            WHEN ENROL.ClassCode like '11TOKIB%'
                THEN '11TOKIB_' + @Year2dgt
            WHEN ENROL.ClassCode in ('8CBHPD', '8DHHPD')
                THEN '8HPD_SW_' + @Year2dgt
            WHEN ENROL.ClassCode in ('9DKHPD', '9ETHPD', '9SKHPD')
                THEN '9HPD_SW_' + @Year2dgt
            WHEN ENROL.ClassCode in ('11AHTG218a', '11ASTG218a', '11KOTG218a')
                THEN ENROL.Classcode + '_'  + @Year2dgt
            WHEN ENROL.ClassNormalYearLevel = 12 
                OR (ENROL.ClassNormalYearLevel = 11 and ENROL.ClassCode like '%IB%')
                OR (Left(ENROL.ClassCode, 2) = '10' AND ENROL.ClassCode like '%ROT%')
			    OR ENROL.ClassCode in (
                    SELECT ClassCode 
                    FROM woodcroft.uCanvasFullYearCourses 
                    WHERE FileYear = @Year4dgt)
                THEN ENROL.ClassCode  + '_' + @Year2dgt
            ELSE ENROL.ClassCode  + '_' + @Year2dgt + '_S' + @Semester
        END AS CanvasCourseId,   

        CASE 
            -- Some Canvas courses use sections based on synergy classes, but most use the default. 
            WHEN ENROL.Role = 'Student' AND ENROL.ClassCode in ('8CBHPD', '8DHHPD', '9ETHPD', '9SKHPD', '9DKHPD') THEN ENROL.ClassCode 
            ELSE ''
        END AS CanvasCourseSection, 

        CASE 
            /* Some courses are 2-year. Where these courses are Y12, they will have a two-year term commencing 
            in the previous year, whereas 2-year Y11 courses have a two-year term commencing in the current year. */
            WHEN LEFT(ENROL.ClassCode, 2) = '12' and ENROL.ClassCode like '%IB%'
                THEN '2Y_' + CAST(@Year4dgt - 1 AS VARCHAR(4))
            WHEN (Left(ENROL.ClassCode, 2) like '11' AND ENROL.ClassCode like '%IB%')
                    OR ENROL.ClassCode in ('11AHTG218a', '11ASTG218a', '11KOTG218a')
                THEN '2Y_' + @Year4dgt
            WHEN Left(ENROL.ClassCode, 2) = '12' 
                OR (Left(ENROL.ClassCode, 2) like '10' AND ENROL.ClassCode like '%ROT%')
			    OR ENROL.ClassCode in (SELECT ClassCode FROM woodcroft.uCanvasFullYearCourses WHERE FileYear = @Year4dgt)
                THEN 'FY_' + @Year4dgt
            ELSE 
                'S'+ @Semester + '_' + @Year4dgt
        END AS CanvasTerm

    FROM (

        /* Student enrollments. */
        SELECT DISTINCT 
            STC.FileYear,
            STC.FileSemester,

            STC.ID AS UserId, 
            COM.OccupEmail AS Email, 
            COM.Given1 AS FirstName,
            COM.Preferred AS PreferredName, 
            COM.Surname AS LastName, 
            CASE 
                WHEN SY.Status = 'LEF' THEN 'deleted' 
                ELSE 'active' 
            END AS UserStatus,

            'Student' AS Role, 
            SUC.ClassCode,
            SUC.Description as ClassDescription,
            SUC.NormalYearLevel as ClassNormalYearLevel,
            CAST(STC.StopDate AS DATE) AS StopDate,
            SUC.LearningAreaCode,
            
            CASE 
                /* Special exceptions for certain students. */ 
                WHEN STC.ID = <STUDENT_ID> AND STC.ClassCode = '8DHHEC' THEN 'Active'
                /* Keep Y11 and Y12 students active in their Canvas courses after their StopDates so teachers 
                and students can access materials through the Christmas break period. */
                WHEN SUC.NormalYearLevel in (11, 12) 
                    AND DATEPART(Month, STC.StopDate) in (10, 11, 12)
                    AND DATEPART(Month, GETDATE()) in (10, 11, 12, 1) THEN 'Active'
                WHEN (STC.StopDate <= GETDATE() OR SY.Status = 'LEF') THEN 'Deleted' 
                ELSE 'Active' 
            END as EnrollmentStatus

        FROM StudentClasses as STC
        LEFT JOIN Community as COM 
            on STC.ID = COM.ID
        INNER JOIN SubjectClasses as SUC
            ON STC.ClassCode = SUC.ClassCode 
            AND STC.FileYear = SUC.FileYear 
            AND STC.FileSemester = SUC.FileSemester
        LEFT JOIN StudentYears as SY
            ON STC.ID = SY.ID 
            AND STC.FileYear = SY.FileYear 
        WHERE SY.YearLevel in (3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
            AND COM.OccupEmail <> ''
            -- Exclude non-academic classes. 
            AND STC.FileType = 'A'
           
        UNION

        /* Teacher enrollments. */ 
        SELECT DISTINCT    
            SCS.FileYear,
            SCS.FileSemester,

            SCS.StaffID AS UserId, 
            COM.OccupEmail AS Email, 
            COM.Given1 AS FirstName,
            COM.Preferred AS PreferredName, 
            COM.Surname AS LastName, 
            'active' AS UserStatus,

            'Teacher' AS CanvasRole, 
            SUC.ClassCode,
            SUC.Description as ClassDescription,
            SUC.NormalYearLevel as ClassNormalYearLevel,
            NULL as StopDate,
            SUC.LearningAreaCode,
            
            'Active' AS EnrollmentStatus

        FROM SubjectClassStaff AS SCS
        LEFT JOIN Community as COM 
            on SCS.StaffID = COM.ID
        INNER JOIN SubjectClasses as SUC
            ON SCS.FileYear = SUC.FileYear 
            AND SCS.FileSemester = SUC.FileSemester 
            AND SCS.ClassCode = SUC.ClassCode
        WHERE COM.OccupEmail <> ''
            -- Exclude non-academic classes. 
            AND SCS.FileType = 'A'
                       
    ) as ENROL
    WHERE
        ENROL.FileYear = @Year4dgt
        AND ENROL.FileSemester = @Semester
        -- Exclude music tuition. 
        AND ENROL.LearningAreaCode <> 'MT'     
        AND ENROL.ClassCode not like '%FocStud%' 
        AND ENROL.ClassCode not like '12Study%'
        AND ENROL.ClassCode not like 'STU%'
        AND ENROL.ClassDescription <> 'Pastoral Care'
        AND ENROL.ClassCode NOT IN (
            SELECT ClassCode 
            FROM woodcroft.uCanvasExcludedCourses 
            WHERE FileYear = @Year4dgt)

    RETURN
END
GO
