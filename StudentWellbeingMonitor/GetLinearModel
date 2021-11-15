CREATE FUNCTION [woodcroft].[utfGetLinearModel](
    @InputData as woodcroft.uLinearModelInputTbl    READONLY
)
RETURNS 

    @Model TABLE (
        ModelID     varchar(500),
        N           decimal(16, 2),
        MeanX       decimal(16, 2),
        MeanY       decimal(16, 2),
        SumX        decimal(16, 2),
        SumY        decimal(16, 2),
        SumX_Pow2   decimal(16, 2),
        SumY_Pow2   decimal(16, 2),
        SumXY       decimal(16, 2),
        Alpha       decimal(16, 2),
        Beta        decimal(16, 2),
        Rho         decimal(16, 2))

AS BEGIN

    /* =============================================================================

    AUTHOR: Benjamin Selby
    DATE:   2021-08-25
       
    Creates a simple linear regression model based on a single predictor 
    variable. 

    INPUTS: 
    
    Input parameter dataset should agree with the following type specification
    which must already exist in the DB:

        CREATE TYPE woodcroft.uLinearModelInputTbl AS TABLE (
            [ModelID]   [varchar](500) NULL,
            [X]         [decimal](16, 2) NULL,
            [Y]         [decimal](16, 2) NULL)

    One model is created for each ModelId frame. So, for a given ModelId, there 
    should be multiple input records which are used to build that model. 

    RETURN VALUES:

    A table containing the models as well as key statistics
    (e.g. MeanX, SumX*Y, Alpha, Beta, etc).
                

    REGRESSION CALCULATIONS: 


        Alpha =     Sum(Y) * Sum(X^2) - Sum(X) * Sum(X * Y)
                    ---------------------------------------
                           N * Sum(X^2) - Sum(X)^2


        Beta =      N * Sum(X * Y)  - Sum(X) * Sum(Y)
                    ---------------------------------
                         N * Sum(X^2) - Sum(X)^2


        Rho  =      Correlation Coefficient
    
             =                   N * Sum(X * Y) - Sum(X) * Sum(Y)
                    -------------------------------------------------------------
                    SQRT( (N * Sum(X^2) - Sum(X)^2) * (N * Sum(Y^2) - Sum(Y)^2) )

    ================================================================================= */


    declare @BasicStats table (
        ModelId     varchar(500),
        N           decimal(16, 2),
        MeanX       decimal(16, 2),
        MeanY       decimal(16, 2),
        SumX        decimal(16, 2),
        SumY        decimal(16, 2),
        SumX_Pow2   decimal(16, 2),
        SumY_Pow2   decimal(16, 2),
        SumXY       decimal(16, 2))
        

    insert into @BasicStats
    select  

        ModelId, 

        CAST(COUNT(*) as DECIMAL(12, 2)) AS N,

        AVG(X) as MeanX,
        AVG(Y) as MeanY,

        SUM(X) as SumX,
        SUM(Y) as SumY,

        SUM(POWER(X, 2)) as SumX_Pow2,
        SUM(POWER(Y, 2)) as SumY_Pow2,

        SUM(X * Y) as SumXY

    from @InputData
    where X is not NULL
        and Y is not NULL
    group by ModelId
    order by ModelId
           

    /* ================================================================ */

 
    insert into @Model
    select 
        STAT.*,

        (STAT.SumY * STAT.SumX_Pow2 - STAT.SumX * STAT.SumXY)
            / (STAT.N * STAT.SumX_Pow2 - POWER(STAT.SumX, 2)) AS Alpha,

        (STAT.N * STAT.SumXY - STAT.SumX * STAT.SumY)
            / (STAT.N * STAT.SumX_Pow2 - POWER(STAT.SumX, 2)) AS Beta,

        (STAT.N * STAT.SumXY - STAT.SumX * STAT.SumY)
            / SQRT(
                (STAT.N * STAT.SumX_Pow2 - POWER(STAT.SumX, 2)) 
                    * (STAT.N * STAT.SumY_Pow2 - POWER(STAT.SumY, 2))
            ) AS Rho

    from @BasicStats as STAT
    order by ModelId

    return 

end

GO


