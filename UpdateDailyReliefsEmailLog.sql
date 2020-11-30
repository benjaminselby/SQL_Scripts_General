USE [CanvasAdmin]
GO

/****** Object:  StoredProcedure [dbo].[spiUpdateDailyReliefsEmailLog]    Script Date: 30/11/2020 10:23:18 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

create procedure [dbo].[spiUpdateDailyReliefsEmailLog]
as begin 

    /* We want to send an email to each teacher containing information about every class which 
    they are relieving for a particular day. We don't want to send an email about a particular class more than 
    once. So, if the email log currently contains an entry for a teacher + class + day, we do not want
    to re-insert it. */ 

    insert into dbo.DailyReliefsEmailLog (
        ReliefDate, 
        ClassCode, 
        ReliefTeacherName,
        ReliefTeacherId,
        ReliefTeacherEmail)

    select distinct 
        cast(GETDATE() as Date),
        ClassCode, 
        ReliefTeacherName, 
        ReliefTeacherId, 
        ReliefTeacherEmail
    from DailyReliefs
    where DATEDIFF(day, datemodified, getdate()) = 0

    except 

    select distinct 
        cast(GETDATE() as Date),
        ClassCode, 
        ReliefTeacherName, 
        ReliefTeacherId, 
        ReliefTeacherEmail
    from DailyReliefsEmailLog
    where DATEDIFF(day, ReliefDate, getdate()) = 0

end
GO


