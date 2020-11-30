USE [CanvasAdmin]
GO

/****** Object:  StoredProcedure [dbo].[spiuAvatarImageUpload]    Script Date: 30/11/2020 10:23:21 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- DROP PROCEDURE dbo.spiuAvatarImageUpload
create procedure [dbo].[spiuAvatarImageUpload] (
    @UserId             INT,
    @CanvasFileId       INT,
    @CanvasFileUuid     VARCHAR(300))
AS BEGIN

    BEGIN TRY 

        IF EXISTS(SELECT * FROM dbo.AvatarImageSync WHERE UserId = @UserId) 
        BEGIN 
            -- Update existing record. 

            UPDATE dbo.AvatarImageSync 
            SET             
                CanvasFileId    = @CanvasFileId,
                CanvasFileUuid  = @CanvasFileUuid
            WHERE UserId = @UserId 

        END
        ELSE BEGIN
            -- Insert new record. 

            INSERT INTO dbo.AvatarImageSync (
                UserId,
                CanvasFileId,
                CanvasFileUuid)
            VALUES (
                @UserId,
                @CanvasFileId,
                @CanvasFileUuid)

        END -- UPDATE/INSERT        

        -- Return success. 
        SELECT 1 as ReturnValue

    END TRY
    BEGIN CATCH

        -- Return failure.
        SELECT 0 as ReturnValue

    END CATCH
    
END
GO


