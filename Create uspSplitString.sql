USE [Synergetic_AUSA_WOODCROFT_PRD]
GO

/****** Object:  UserDefinedFunction [woodcroft].[uspSplitString]    Script Date: 10/08/2021 12:05:03 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE function [woodcroft].[uspSplitString] (
    @String      nvarchar(max),
    @Delimiter  nvarchar(50)
)
returns @ReturnTable table (
    Seq     int primary key identity(1, 1),
    Value   nvarchar(max)
)
as begin

    /* Splits a delimited string and returns a set of records, with one delimited 
    value per row. */ 

    declare @Xml xml = cast('<d>' + replace(@String, @Delimiter, '</d><d>') + '</d>' as xml)

    insert into @ReturnTable
            (Value)
    select  T.xmlData.value('.', 'nvarchar(max)') as Value
    from    @Xml.nodes('/d') T(xmlData)
    
    return
    
end
GO
