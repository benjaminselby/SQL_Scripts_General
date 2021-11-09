ALTER PROCEDURE [woodcroft].[uspsGetAcademicTrendFlags] (

    /* 
    If this parameter is not supplied, results will be returned 
    for all students. 
    */
    @StudentId          int = NULL,

    /*
    The Year and Term to treat as 'unknown' and then flag if the actual 
    value differs significantly from the predicted value. 
    */
    @PredictedYear      int = NULL,
    @PredictedTerm      int = NULL,

    /* 
    If set to 1, output will include additional columns. 
    */
    @DetailedOutput     bit = 0,

    /* 
    The minimum number of data points for forming a regression model for a student, 
    PLUS 1 to include the most recent result which will be removed and 'predicted'. 
    Note that this needs to be at least greater than 2 to prevent divide by zero errors 
    in StdError calculations etc. 
    */
    @MinDataPoints int = 7,

    /* Things were a bit dodgy in Synergy before 2016, so we don't read from 
    years prior to this. */
    @HistoryCutoffYear int = 2016,

    /* Only develop models for students currently in this year level and higher. 
    However, we DO use grades from lower years for these students if those are 
    available. */
    @StudentMinYearLevel int = 7,

    /* 
    Standard critical value for confidence intervals. I believe it's more 
    proper to use a t value which varies according to degrees of freedom. 
    Might implement this in future, but for now the standard values will be fine. 
    95% interval => 1.96
    99% interval => 2.58 
    */
    @IntervalCriticalValue decimal(16,2) = 2.58,
    
    /*
    Used to identify students with significantly positive or negative
    trends. If the regression Beta for a student is at a value lower
    or higher than the values at these percentile ranks, we flag it.
    */
    @BetaLowPercentileRank decimal(16,2) = 0.05,
    @BetaHighPercentileRank decimal(16,2) = 0.95

)    

AS BEGIN TRY

    /*
    AUTHOR: Benjamin Selby
    DATE:   2021-08-24

    This is part of a system which will flag students who deviate significantly
    from their 'normal' performance. The primary purpose will be to identify students
    who may be experiencing some personal circumstances which are affecting their 
    performance negatively. However, it may also be used to identify students who 
    vary significantly in a positive direction. 

    This component encompasses academic results, but later we intend to incorporate
    a variety of metrics of student wellbeing/performance such as: detentions, 
    counsellor comments, sick bay visits, absences from classes, etc. 

    This procedure treats the most recent academic result as being 'unknown'. The N-1 
    remaining results are used to create a regression model for that performance 
    category. This model is used to predict the most recent result and to create 
    confidence intervals around the prediction. If the 'true' most recent result is 
    outside of the confidence intervals, then it is flagged as anomalous. 

    PREDICTION INTERVAL: "... a prediction interval is an estimate of an interval 
        in which a future observation will fall, with a certain probability, given 
        what has already been observed." 
        Source: https://en.wikipedia.org/wiki/Prediction_interval

    Notes: 

        - Tried using table variables but they made the script very, very slow. 
        Replaced with temp tables (#).
        
    TODO: 
    
        - If this is called with a single StudentID value, the trend flag will not 
        be correct, because the student is being compared to themselves and not
        the rest of the school. 

    */

    
    SET NOCOUNT ON
    SET FMTONLY OFF


    /* ========================================================================== */

    /* 
    Default values if parameters have not been set. 
    */

    SET @PredictedYear = ISNULL(@PredictedYear, 
        CASE 
            WHEN DATEPART(MONTH, GETDATE()) <= 4  THEN DATEPART(YEAR, GETDATE()) - 1
            ELSE DATEPART(YEAR, GETDATE())
        END)

    SET @PredictedTerm = ISNULL(@PredictedTerm, 
        CASE 
            -- Last term of previous year.
            WHEN DATEPART(MONTH, GETDATE()) <= 4  THEN 4 
            WHEN DATEPART(MONTH, GETDATE()) <= 6  THEN 1
            WHEN DATEPART(MONTH, GETDATE()) <= 9  THEN 2
            ELSE 3
        END)  


    /* ========================================================================== */


    if OBJECT_ID('tempdb.dbo.#CurrentStudents') is not NULL drop table #CurrentStudents
    create table #CurrentStudents (
        ID  int)


    if @StudentId IS NOT NULL
    begin 
        insert into #CurrentStudents (ID)
        VALUES (@StudentId)
    end 
    else begin
        insert into #CurrentStudents
        select distinct ID
        from StudentYears
        where FileYear = DATEPART(YEAR, GETDATE())
            AND Status <> 'LEF'
            AND YearLevel >= @StudentMinYearLevel
    end    



    if OBJECT_ID('tempdb.dbo.#StudentResults') is not NULL drop table #StudentResults
    create table #StudentResults (
        ID                      int,
        Year                    int,
        Semester                int,
        Term                    int,
        StudentYearLevel        int,
        ClassCode               varchar(200),
        ClassDescription        varchar(500),
        ClassNormalYearLevel    int,
        AssessmentCode          varchar(200),
        AssessmentAreaSeq       int,
        AssessmentAreaHeading   varchar(200),
        ResultType              varchar(200),
        Result                  varchar(100),
        ResultNumeric           decimal(16,2),
        ResultCategory          varchar(200))


    insert into #StudentResults
    select 
        SAR.ID, 
        SAR.FileYear, 
        SAR.FileSemester, 
        SAR.Term,
        SAR.StudentYearLevel,
        SAR.ClassCode, 
        SAR.ClassDescription, 
        SAR.ClassNormalYearLevel, 
        SAR.AssessmentCode,
        SAR.AssessmentAreaSeq,
        SAR.AssessmentAreaHeading,
        SAR.ResultType,
        SAR.Result, 

        /* =============================================================================== */
        /* Convert all academic results to numeric values ranging from 0-100 
            to enable comparison. */
        /* =============================================================================== */

        CASE 
            WHEN SAR.ResultType = '$Attribute' THEN 
                CASE 
                    WHEN SAR.Result = 'Unsatisfactory'          THEN 0.0
                    WHEN SAR.Result = 'Inconsistent'            THEN 33.3
                    WHEN SAR.Result = 'Meets'                   THEN 66.6
                    WHEN SAR.Result in ('Excels', 'Exceeds')    THEN 100.0
                END

            WHEN SAR.ResultType in ('$IBD', '$MYPCalc', '$MYPGrade') THEN 
                CASE 
                    WHEN SAR.Result = 1 THEN 0.0
                    WHEN SAR.Result = 2 THEN 16.6
                    WHEN SAR.Result = 3 THEN 33.3
                    WHEN SAR.Result = 4 THEN 49.9
                    WHEN SAR.Result = 5 THEN 66.5
                    WHEN SAR.Result = 6 THEN 83.1
                    WHEN SAR.Result = 7 THEN 100.0
                END

            WHEN SAR.ResultType = '$MYPCriteria' THEN 
                CASE 
                    WHEN SAR.Result = 0 THEN 0.0
                    WHEN SAR.Result = 1 THEN 12.5
                    WHEN SAR.Result = 2 THEN 25.0
                    WHEN SAR.Result = 3 THEN 37.5
                    WHEN SAR.Result = 4 THEN 50.0
                    WHEN SAR.Result = 5 THEN 62.5
                    WHEN SAR.Result = 6 THEN 75.0
                    WHEN SAR.Result = 7 THEN 87.5
                    WHEN SAR.Result = 8 THEN 100.0
                END

            WHEN SAR.ResultType = '$SACEGrade' THEN 
                CASE 
                    WHEN SAR.Result = 'E-'  THEN 0.0
                    WHEN SAR.Result = 'E'   THEN 7.1
                    WHEN SAR.Result = 'E+'  THEN 14.3
                    WHEN SAR.Result = 'D-'  THEN 21.4
                    WHEN SAR.Result = 'D'   THEN 28.6
                    WHEN SAR.Result = 'D+'  THEN 35.7
                    WHEN SAR.Result = 'C-'  THEN 42.9
                    WHEN SAR.Result = 'C'   THEN 50.0
                    WHEN SAR.Result = 'C+'  THEN 57.1
                    WHEN SAR.Result = 'B-'  THEN 64.3
                    WHEN SAR.Result = 'B'   THEN 71.4
                    WHEN SAR.Result = 'B+'  THEN 78.6
                    WHEN SAR.Result = 'A-'  THEN 85.7
                    WHEN SAR.Result = 'A'   THEN 92.9
                    WHEN SAR.Result = 'A+'  THEN 100.0
                END

            WHEN SAR.ResultType = '0-7' THEN 
                CASE 
                    WHEN SAR.Result = 0 THEN 0.0
                    WHEN SAR.Result = 1 THEN 14.3
                    WHEN SAR.Result = 2 THEN 28.6
                    WHEN SAR.Result = 3 THEN 42.9
                    WHEN SAR.Result = 4 THEN 57.1
                    WHEN SAR.Result = 5 THEN 71.4
                    WHEN SAR.Result = 6 THEN 85.7
                    WHEN SAR.Result = 7 THEN 100.0
                END

            WHEN SAR.ResultType = 'OHCCDNYE' THEN 
                CASE 
                    WHEN SAR.Result = 'NYE' THEN 0.0
                    WHEN SAR.Result = 'D'   THEN 25.0
                    WHEN SAR.Result = 'C'   THEN 50.0
                    WHEN SAR.Result = 'HC'  THEN 75.0
                    WHEN SAR.Result = 'O'   THEN 100.0
                END                
            ELSE 
                NULL

        END as ResultNumeric,

        /* =============================================================================== */
        
        /* Create category headings for result types. */
        case 
            when SAR.ResultType in ('$Attribute') then 'Attribute'
            when SAR.ResultType in ('$MYPCriteria') then 'MypCriteria'
            else 'Grade'
        end as ResultCategory

    from woodcroft.uvAllStudentAssessmentResults as SAR
    where 

        SAR.ID in (
            select distinct ID
            from #CurrentStudents)

        and SAR.FileYear >= @HistoryCutoffYear
        and SAR.Term in ('1', '2', '3', '4')

        /* Make sure we don't select any new results which may exist after the 
        'most recent' year and term that we are focusing on. */
        and (
            case 
                when ISNUMERIC(SAR.FileYear) = 1 then SAR.FileYear
                else 99999
            end < @PredictedYear

            or 

            case 
                when ISNUMERIC(SAR.FileYear) = 1 and SAR.FileYear = @PredictedYear
                    and ISNUMERIC(SAR.Term) = 1 then SAR.Term
                else 999
            end <= @PredictedTerm)
            
        /* Currently we will use grades for years below the current student cutoff
        if those are available (ie. Junior School). Not sure if this will work out. */
        --and SAR.StudentYearLevel >= @StudentMinYearLevel

        and Result not in ('', 'NA', 'Abs', 'Not Relevant')
        and Result is not NULL

        and SAR.LearningAreaCode <> 'MT'
        and AssessmentCode not like 'MusicTutor%'

        and ResultType not in ('ServiceLearning', 'Instrument', 'MTutMain')
        and ResultType not like 'WISE%'
        and ResultType not like 'Reception%'
        
        and not (
            ResultType = 'OHCCDNYE'
            and Result in ('M', 'U', 'A', 'S', 'NA'))

        and not (
            ResultType = '$SACEGrade'
            and Result in ('U', 'Abs'))

        and AssessmentAreaHeading <> 'Community Service Hours'
    order by ResultType, result
       


    /* ======================================================================================= */
    

    /* 
    Create a framework of time points as a base for our results table. 
    This is necessary so that results which do not exist for a particular date
    cause a gap rather than that date point simply being skipped.
    This is important for building the models. 
    */

    -- set nocount on

    declare @StudentIdCounter   int

    declare @YearCounter        int = @HistoryCutoffYear
    
    declare @TermCounterStart   int = 1
    declare @TermCounterStop    int = 4
    declare @TermCounter        int


    if OBJECT_ID('tempdb.dbo.#DatePoints') is not NULL drop table #DatePoints
    create table #DatePoints (
        Year        int,
        Term        int)


    while @YearCounter <= @PredictedYear
    begin 

        set @TermCounter = @TermCounterStart
    
        while @TermCounter <= @TermCounterStop
        begin 

            insert into #DatePoints
            select 
                @YearCounter,
                @TermCounter

            if @YearCounter = @PredictedYear 
                    and @TermCounter = @PredictedTerm
                break

            set @TermCounter += 1
        end

        set @YearCounter += 1

    end

    -- set nocount off


    /* 
    Add all the available result categories for each student onto the 
    date points table so we have a basis with all possible permutations. 
    We need to do this so that regression model building will treat 
    missing values correctly. 
    */


    if OBJECT_ID('tempdb.dbo.#CategoriesByDate') is not NULL drop table #CategoriesByDate
    create table #CategoriesByDate (
        ID                  int,
        ResultCategory      varchar(200),
        Year                int,
        Term                int,
        DateRank            decimal(16,2))
            

    insert into #CategoriesByDate
    select distinct 
        SR.ID,
        SR.ResultCategory, 
        DP.Year, 
        DP.Term,
        -- This will be used as the X variable for model building. 
        CAST(ROW_NUMBER() over (
            partition by SR.ID, SR.ResultCategory
            order by DP.Year, DP.Term) AS DECIMAL(12,2)
            ) as DateRank
    from #DatePoints as DP
    -- CROSS JOIN creates all possible combinations. 
    CROSS JOIN (
            select distinct 
                ID, 
                ResultCategory
            from #StudentResults
        
            union 

            select distinct 
                ID, 
                'Overall'
            from #StudentResults
        ) as SR
    order by SR.ID, SR.ResultCategory, DateRank

       

    /* ======================================================================= */



    if OBJECT_ID('tempdb.dbo.#AverageResults') is not NULL drop table #AverageResults
    create table #AverageResults (
        ID                      int,
        Year                    int,
        Term                    int,
        StudentYearLevel        int,
        ResultCategory          varchar(200),
        AverageResult           decimal(16,2))

        
    insert into #AverageResults
    select 
        SR.ID, 
        SR.Year, 
        SR.Term,
        SR.StudentYearLevel,
        SR.ResultCategory,
        AVG(SR.ResultNumeric) as AverageResult
    from #StudentResults as SR
    group by 
        SR.Year,
        SR.Term,
        SR.ID, 
        SR.StudentYearLevel, 
        SR.ResultCategory

    union
    
    select 
        SR.ID, 
        SR.Year, 
        SR.Term,
        SR.StudentYearLevel,
        'Overall' as ResultCategory,
        AVG(SR.ResultNumeric) as AverageResult
    from #StudentResults as SR
    group by 
        SR.Year,
        SR.Term,
        SR.ID, 
        SR.StudentYearLevel

    order by ID, ResultCategory, Year, Term


    /* ======================================================================= */


    /*
    Merge average results onto date points & categories table so each student 
    has the same date points, with NULL values where results are missing. 
    */


    if OBJECT_ID('tempdb.dbo.#AveragesByDate') is not NULL drop table #AveragesByDate
    create table #AveragesByDate (
        ID                      int,
        ResultCategory          varchar(200),
        Year                    int,
        Term                    int,
        DateRank                decimal(16,2),
        StudentYearLevel        int,
        AverageResult           decimal(16,2))
     

    insert into #AveragesByDate
    select 
        CBD.ID,
        CBD.ResultCategory,
        CBD.Year,
        CBD.Term,
        CBD.DateRank,
        AVG.StudentYearLevel,
        AVG.AverageResult
    from #CategoriesByDate as CBD
    left join #AverageResults as AVG
        on CBD.ID = AVG.ID
        and CBD.ResultCategory = AVG.ResultCategory
        and CBD.Year = AVG.Year
        and CBD.Term = AVG.Term
    order by CBD.id, CBD.ResultCategory, CBD.DateRank


    
    /* 
    Remove any {Student, ResultCategory} combinations where there are not 
    the minimum number of data points within that result category
    required for building our models. 
    */
       
    if OBJECT_ID('tempdb.dbo.#Filtered') is not NULL drop table #Filtered
    create table #Filtered (
        ID                      int,
        ResultCategory          varchar(200),
        Year                    int,
        Term                    int,
        DateRank                decimal(16, 2),
        StudentYearLevel        int,
        AverageResult           decimal(16,2))

    
    insert into #Filtered
    select 
        ABD.ID,
        ABD.ResultCategory,
        ABD.Year,
        ABD.Term,
        ABD.DateRank,
        ABD.StudentYearLevel,
        ABD.AverageResult
        --, AVG2.ID as MatchedId
    from #AveragesByDate as ABD
    left join (
            Select 
                ID, 
                ResultCategory,
                count(*) as N
            from #AverageResults as AVG
            group by 
                ID, 
                ResultCategory
            having count(*) >= @MinDataPoints
        ) as COUNTS
        on ABD.ID = COUNTS.ID
        and ABD.ResultCategory = COUNTS.ResultCategory
    where COUNTS.ID IS NOT NULL    
    order by ID, ResultCategory, DateRank


    /* 
    Delete all rows for any result category if there is no result in 
    this category for this student at the most recent time point. 
    */

    delete FLT
    from #Filtered as FLT
    left join (
            select distinct 
                ID, 
                ResultCategory 
            from #Filtered 
            where 
                Year = @PredictedYear
                and Term = @PredictedTerm
                and AverageResult is NULL
        ) as MISSING
        on FLT.ID = MISSING.ID
            and FLT.ResultCategory = MISSING.ResultCategory
    where MISSING.ID is not NULL



    /* 
    Split the data to separate out the most recent results. 
    These will be 'predicted' using the N-1 remaining results. 
    If the predicted result and the actual result are significantly 
    different, then this difference will be considered to be 
    significant. 
    */

    

    if OBJECT_ID('tempdb.dbo.#PredictedResults') is not NULL drop table #PredictedResults
    create table #PredictedResults (
        ID                      int,
        ResultCategory          varchar(200),
        Year                    int,
        Term                    int,
        DateRank                decimal(16, 2),
        StudentYearLevel        int,
        AverageResult           decimal(16,2))
            

    insert into #PredictedResults
    select 
        FLT.ID,
        FLT.ResultCategory,
        FLT.Year,
        FLT.Term,
        FLT.DateRank,
        FLT.StudentYearLevel,
        FLT.AverageResult
    from #Filtered as FLT
    where FLT.DateRank = (
            select Max(FLT2.DateRank)
            from #Filtered as FLT2
            where FLT.ID = FLT2.ID
            and FLT2.ResultCategory = FLT2.ResultCategory)
    order by ID, ResultCategory, DateRank

    

    if OBJECT_ID('tempdb.dbo.#RemainingResults') is not NULL drop table #RemainingResults
    create table #RemainingResults (
        ID                      int,
        ResultCategory          varchar(200),
        Year                    int,
        Term                    int,
        DateRank                decimal(16, 2),
        StudentYearLevel        int,
        AverageResult           decimal(16,2))

    
    insert into #RemainingResults
    select 
        FLT.ID,
        FLT.ResultCategory,
        FLT.Year,
        FLT.Term,
        FLT.DateRank,
        FLT.StudentYearLevel,
        FLT.AverageResult
    from #Filtered as FLT
    where FLT.DateRank < (
        select Max(MAX_DR.DateRank)
        from #Filtered as MAX_DR
        where FLT.ID = MAX_DR.ID
        and FLT.ResultCategory = MAX_DR.ResultCategory)
    order by ID, ResultCategory, DateRank



    /* =============================================================================== */
    /* CALL LINEAR MODELLING FUNCTION. */
    /* =============================================================================== */


    /* This is required as an input variable type for the modelling function. 
    
    CREATE TYPE woodcroft.uLinearModelInputTbl AS TABLE (
        ID          int,
        Groups      varchar(200),
        X           decimal(16, 2),
        Y           decimal(16, 2))
    */

    DECLARE @ModelInput woodcroft.uLinearModelInputTbl

    insert into @ModelInput(
        ID, 
        Groups, 
        X, 
        Y)
    select 
        ID,
        ResultCategory,
        DateRank,
        AverageResult
    from #RemainingResults
    

    if OBJECT_ID('tempdb.dbo.#ModelOutput') is not NULL drop table #ModelOutput
    create table #ModelOutput (
        ID                      int,
        ResultCategory          varchar(200),
        N                       int,
        MeanX                   decimal(16,2),
        MeanY                   decimal(16,2),
        SumX                    decimal(16,2),
        SumY                    decimal(16,2),
        SumX_Pow2               decimal(16,2),
        SumY_Pow2               decimal(16,2),
        SumXY                   decimal(16,2),
        Alpha                   decimal(16,2),
        Beta                    decimal(16,2),
        Rho                     decimal(16,2))  

    
    insert into #ModelOutput
    select 
        ID,
        Groups,
        N,
        MeanX,
        MeanY,
        SumX,
        SumY,
        SumX_Pow2,
        SumY_Pow2,
        SumXY,
        Alpha,
        Beta,
        Rho
    from woodcroft.utfGetLinearModel(@ModelInput)
    order by id, Groups
       
       

    /* =============================================================================== */
    /* Now compute error statistics and develop confidence intervals around predicted 
        Y values. */
    /* =============================================================================== */

    /*
        Standard Error of the Estimate 
        
            =       SE(est)

            =       SQRT( Mean Square Residual )

                    (    ( Actual(Y) - Predicted(Y) )^2     )
            =   SQRT( ------------------------------------- )
                    (                 N - 2                 )


        Sum of Squares(X) 
    
            =   SS(X)

            =   SUM( (X' - Mean(X))^2 )


        Standard Error of the Prediction at X'
        (Note that this changes for different values of X')

                                  (           (X' - Mean(X))^2 )
            =       SE(est) * SQRT( 1 + 1/N + ---------------- )
                                  (                 SS(X)      ) 

    */

       
    if OBJECT_ID('tempdb.dbo.#Predicted') is not NULL drop table #Predicted
    create table #Predicted (
        ID                      int,
        ResultCategory          varchar(200),
        Year                    int,
        Term                    int,
        DateRank                decimal(16, 2),
        StudentYearLevel        int,
        AverageResult           decimal(16,2),
        N                       int,
        MeanX                   decimal(16,2),
        MeanY                   decimal(16,2),
        SumX                    decimal(16,2),
        SumY                    decimal(16,2),
        SumX_Pow2               decimal(16,2),
        SumY_Pow2               decimal(16,2),
        SumXY                   decimal(16,2),
        Alpha                   decimal(16,2),
        Beta                    decimal(16,2),
        Rho                     decimal(16,2),  
        DeviationX              decimal(16,2),
        DeviationY              decimal(16,2),
        PredY                   decimal(16,2),
        ResidY_Pow2             decimal(16,2))

                
    insert into #Predicted
    select
        RES.*,
        MOD.N,
        MOD.MeanX,
        MOD.MeanY,
        MOD.SumX,
        MOD.SumY,
        MOD.SumX_Pow2,
        MOD.SumY_Pow2,
        MOD.SumXY,
        MOD.Alpha,
        MOD.Beta,
        MOD.Rho,
        RES.DateRank - MOD.MeanX as DeviationX,
        RES.AverageResult - MOD.MeanY as DeviationY,
        MOD.Alpha + RES.DateRank * MOD.Beta as PredY,
        POWER(RES.AverageResult - (MOD.Alpha + RES.DateRank * MOD.Beta), 2 
            ) as ResidY_Pow2    
    from (
            /* Join most recent results back onto the results 
            we used for model building. */
            SELECT 
                ID,
                ResultCategory,
                Year,
                Term,
                DateRank,
                StudentYearLevel,
                AverageResult                
            from #RemainingResults 

            union 

            select 
                ID,
                ResultCategory,
                Year,
                Term,
                DateRank,
                StudentYearLevel,
                AverageResult
            from #PredictedResults
        ) as RES
    left join #ModelOutput AS MOD
        on RES.ID = MOD.ID
        and RES.ResultCategory = MOD.ResultCategory
    order by RES.ID, RES.ResultCategory, RES.DateRank

        

    if OBJECT_ID('tempdb.dbo.#SumSquares') is not NULL drop table #SumSquares
    create table #SumSquares (
        ID                  int,
        ResultCategory      varchar(200),
        SumSqDevX           decimal(16, 2),
        SumSqResid          decimal(16,2))


    insert into #SumSquares
    select 
        PRD.ID,
        PRD.ResultCategory,
        SUM(POWER(PRD.DeviationX, 2)) AS SumSqDevX,
        SUM(PRD.ResidY_Pow2) as SumSqResid
    from #Predicted as PRD
    where 
        /* Exclude rows which were not used in model building. */
        PRD.DateRank is not NULL
        and PRD.AverageResult is not NULL
        and PRD.DateRank < (
            select MAX(DateRank)
            from #Predicted as MAX
            where PRD.ID = MAX.ID
                and PRD.ResultCategory = MAX.ResultCategory)
    group by 
        ID, 
        ResultCategory
    order by ID, ResultCategory
    


    if OBJECT_ID('tempdb.dbo.#StdErrEstimate') is not NULL drop table #StdErrEstimate
    create table #StdErrEstimate (
        ID                  int,
        ResultCategory      varchar(200),
        SumSqDevX           decimal(16, 2),
        SumSqResid          decimal(16, 2),
        StdErrEstimate      decimal(16,2))


    insert into #StdErrEstimate
    select DISTINCT
        PRD.ID,
        PRD.ResultCategory,
        SS.SumSqDevX,
        SS.SumSqResid,
        SQRT(
            SS.SumSqResid / ( PRD.N - 2 )
        ) as StdErrEstimate
    from #Predicted as PRD
    left join #SumSquares as SS
        on PRD.ID = SS.ID
        and PRD.ResultCategory = SS.ResultCategory
    order by PRD.ID, PRD.ResultCategory
    

   
    /* ====================================================================================== */
    
    

    /* 
    Calculate the prediction error values. Note that these are different 
    at different values of X. 
    */

    if OBJECT_ID('tempdb.dbo.#StdErrPrediction') is not NULL drop table #StdErrPrediction
    create table #StdErrPrediction (
        ID                      int,
        ResultCategory          varchar(200),
        Year                    int,
        Term                    int,
        DateRank                decimal(16, 2),
        StudentYearLevel        int,
        AverageResult           decimal(16,2),
        N                       int,
        MeanX                   decimal(16,2),
        MeanY                   decimal(16,2),
        SumX                    decimal(16,2),
        SumY                    decimal(16,2),
        SumX_Pow2               decimal(16,2),
        SumY_Pow2               decimal(16,2),
        SumXY                   decimal(16,2),
        Alpha                   decimal(16,2),
        Beta                    decimal(16,2),
        Rho                     decimal(16,2),  
        DeviationX              decimal(16,2),
        DeviationY              decimal(16,2),
        PredY                   decimal(16,2),
        ResidY_Pow2             decimal(16,2),
        StdErrEstimate          decimal(16,2),
        StdErrPrediction        decimal(16,2))       


    insert into #StdErrPrediction    
    select 

        PRD.*,
        SE.StdErrEstimate,
        SE.StdErrEstimate * SQRT( 
            1 + 1/CAST(PRD.N AS DECIMAL(16,2)) 
                + POWER(PRD.DateRank - PRD.MeanX, 2) / SS.SumSqDevX
        ) as StdErrPrediction

    from #Predicted as PRD
    left join #StdErrEstimate as SE
        on PRD.ID = SE.ID
        and PRD.ResultCategory = SE.ResultCategory
    left join #SumSquares as SS
        on PRD.ID = SS.ID
        and PRD.ResultCategory = SS.ResultCategory
    order by ID, ResultCategory, DateRank



    /* Develop confidence intervals for the prediction. */


    if OBJECT_ID('tempdb.dbo.#PredictionMargins') is not NULL drop table #PredictionMargins
    create table #PredictionMargins (
        ID                      int,
        ResultCategory          varchar(200),
        Year                    int,
        Term                    int,
        DateRank                decimal(16, 2),
        StudentYearLevel        int,
        AverageResult           decimal(16,2),
        N                       int,
        MeanX                   decimal(16,2),
        MeanY                   decimal(16,2),
        SumX                    decimal(16,2),
        SumY                    decimal(16,2),
        SumX_Pow2               decimal(16,2),
        SumY_Pow2               decimal(16,2),
        SumXY                   decimal(16,2),
        Alpha                   decimal(16,2),
        Beta                    decimal(16,2),
        Rho                     decimal(16,2),  
        DeviationX              decimal(16,2),
        DeviationY              decimal(16,2),
        PredY                   decimal(16,2),
        ResidY_Pow2             decimal(16,2),
        StdErrEstimate          decimal(16,2),
        StdErrPrediction        decimal(16,2),
        PredIntLow              decimal(16,2),
        PredIntHigh             decimal(16,2))      


    insert into #PredictionMargins       
    select 
        SEP.*,
        SEP.PredY - @IntervalCriticalValue * SEP.StdErrPrediction as PredIntLow,
        SEP.PredY + @IntervalCriticalValue * SEP.StdErrPrediction as PredIntHigh
    from #StdErrPrediction as SEP


    /* 
    In order to determine if the slope of the trendline for a particular 
    student is significantly different to normal, get low and high percentile 
    values for the Betas and use those later to flag any students with Beta values 
    over/under them. 
    */

    
    if OBJECT_ID('tempdb.dbo.#BetaPercentiles') is not NULL drop table #BetaPercentiles
    create table #BetaPercentiles (
        ResultCategory      varchar(200), 
        LowPercentile       decimal(16,2),
        HighPercentile      decimal(16,2))


    insert into #BetaPercentiles
    select distinct 
        ResultCategory, 

        PERCENTILE_CONT(@BetaLowPercentileRank) 
            within group (order by beta asc) 
            over (partition by ResultCategory) 
            as LowPercentile,

        PERCENTILE_CONT(@BetaHighPercentileRank) 
            within group (order by beta asc) 
            over (partition by ResultCategory) 
            as HighPercentile
    from #PredictionMargins

          

    /* ====================================================================================== */
    /* Set flags. */
    /* ====================================================================================== */


               
    if OBJECT_ID('tempdb.dbo.#Flagged') is not NULL drop table #Flagged
    create table #Flagged (
        ID                  int,
        ResultCategory      varchar(200),
        Year                int,
        Term                int,
        DateRank            decimal(16, 2),
        StudentYearLevel    int,
        AverageResult       decimal(16,2),
        N                   decimal(16, 2),
        MeanX               decimal(16, 2),
        MeanY               decimal(16, 2),
        SumX                decimal(16, 2),
        SumY                decimal(16, 2),
        SumX_Pow2           decimal(16, 2),
        SumY_Pow2           decimal(16, 2),
        SumXY               decimal(16, 2),
        DeviationX          decimal(16, 2),
        DeviationY          decimal(16, 2),
        Alpha               decimal(16,2),
        Beta                decimal(16,2),
        Rho                 decimal(16,2),  
        PredY               decimal(16, 2),
        ResidY_Pow2         decimal(16, 2),
        StdErrEstimate      decimal(16, 2),
        StdErrPrediction    decimal(16, 2),
        PredIntLow          decimal(16,2),  
        PredIntHigh         decimal(16,2),  
        BetaLowPercentile   decimal(16,2),  
        BetaHighPercentile  decimal(16,2),  
        TrendFlag           varchar(100),
        MarginFlag          varchar(100))
    

    insert into #Flagged
    select 
        PM.ID,
        PM.ResultCategory,
        PM.Year,
        PM.Term,
        PM.DateRank,
        PM.StudentYearLevel,
        PM.AverageResult,
        PM.N,
        PM.MeanX,
        PM.MeanY,
        PM.SumX,
        PM.SumY,
        PM.SumX_Pow2,
        PM.SumY_Pow2,
        PM.SumXY,
        PM.DeviationX,
        PM.DeviationY,
        PM.Alpha,
        PM.Beta,
        PM.Rho,
        PM.PredY,
        PM.ResidY_Pow2,
        PM.StdErrEstimate,
        PM.StdErrPrediction,

        PM.PredIntLow,
        PM.PredIntHigh,

        PCT.LowPercentile,
        PCT.HighPercentile,

        /* Flag students whose trend is within a low or high percentile. 
        Only flag the row containing the most recent result. */
        CASE
            when PM.DateRank = LAST_VALUE(PM.DateRank) over (
                    partition by PM.ID, PM.ResultCategory 
                    order by PM.DateRank
                    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)                 
                then 


                    case 
                        when PM.Beta <= PCT.LowPercentile then 'LOW'
                        when PM.Beta >= PCT.HighPercentile then 'HIGH' 
                        else NULL
                    end 
            ELSE 
                NULL
        END as TrendFlag,

        /* Flag students whose most recent result is significantly lower  
        or higher than predicted. */
        case 
            -- Only flag the row containing the most recent result. 
            when PM.DateRank = LAST_VALUE(PM.DateRank) over (
                    partition by PM.ID, PM.ResultCategory 
                    order by PM.DateRank
                    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)                 
                then 
                    case 
                        when PM.AverageResult < PM.PredIntLow
                            then 'LOW'
                        when PM.AverageResult > PM.PredIntHigh
                            then 'HIGH'
                    end
            else 
                NULL
        end as MarginFlag

    from #PredictionMargins as PM
    left join #BetaPercentiles as PCT
        on PM.ResultCategory = PCT.ResultCategory


    /* ========================================================================= */
    /* Finished. */
    /* ========================================================================= */


    if @DetailedOutput = 0 
    begin 

        select 
            ID,
            ResultCategory,
            Year,
            Term,
            DateRank,
            StudentYearLevel,
            AverageResult,
            N,
            Alpha,
            Beta,
            Rho,
            StdErrPrediction,
            PredIntLow,
            PredIntHigh,
            BetaLowPercentile,
            BetaHighPercentile,
            TrendFlag,
            MarginFlag
        from #Flagged
        order by ID, ResultCategory, DateRank

    end
    else begin 

        select *
        from #Flagged
        order by ID, ResultCategory, DateRank

    end 

END TRY

BEGIN CATCH

     SELECT 
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_SEVERITY() AS ErrorSeverity,
        ERROR_STATE() AS ErrorState,
        ERROR_PROCEDURE() AS ErrorProcedure,
        ERROR_LINE() AS ErrorLine,
        ERROR_MESSAGE() AS ErrorMessage;
        
END CATCH


GO
