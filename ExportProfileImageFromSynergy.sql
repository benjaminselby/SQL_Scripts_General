USE [CanvasAdmin]
GO

/****** Object:  StoredProcedure [dbo].[spsExportSynergyProfileImage]    Script Date: 30/11/2020 10:23:32 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[spsExportSynergyProfileImage] (
    @UserId             NVARCHAR(10),
    @ExportFolderPath   NVARCHAR(1000),
    @Filename           NVARCHAR(1000))
AS BEGIN

    /* 
    Author: Benjamin Selby. 
    Date:   2020/09/03
    Notes:  Exports a profile image from the Synergy MS SQL Server database. 
        Returns 1 if an image is successfully exported for the given UserId. 
        Returns 0 if no image is found for that user. 
    */

    DECLARE @ImageData       VARBINARY(MAX);
    DECLARE @OutputPath      NVARCHAR(2000);
    DECLARE @ObjId           INT
 
    SET NOCOUNT ON
 
    SELECT @ImageData = (
        SELECT Thumbnail 
        FROM Synergy.Synergetic_AUSA_WOODCROFT_PRD.media.Photos 
        where id = @UserId)
 
    IF @ImageData IS NULL BEGIN

        -- No image available for this user. 
        SELECT 0 as ReturnValue
        GOTO Exit_Procedure

    END
    ELSE BEGIN         

        -- OK, image for this user is available. Export to folder. 

        SET @OutputPath = CONCAT(@ExportFolderPath,'\', @Filename)

        BEGIN TRY
            EXEC sp_OACreate 'ADODB.Stream', @ObjId OUTPUT
            EXEC sp_OASetProperty @ObjId ,'Type',1
            EXEC sp_OAMethod @ObjId,'Open'
            EXEC sp_OAMethod @ObjId,'Write', NULL, @ImageData
            EXEC sp_OAMethod @ObjId,'SaveToFile', NULL, @OutputPath, 2
            EXEC sp_OAMethod @ObjId,'Close'
            EXEC sp_OADestroy @ObjId
        END TRY
        BEGIN CATCH
            EXEC sp_OADestroy @ObjId
            print 'error'
        END CATCH

        SELECT 1 as ReturnValue
        GOTO Exit_Procedure

    END

Exit_Procedure:
    SET NOCOUNT OFF
END
GO


