function manifest()
    return {
        name          = "Export VSQ(103)",
        comment       = "Export as VSQ",
        author        = "kbinani_103",
        pluginID      = "{6B11244F-FA7B-4804-AA0D-2D3AE2E392E3}",
        pluginVersion = "1.2.0.0",
        apiVersion    = "3.0.0.2"
    };
end

function main( processParam, envParam )
    local scriptDirectory = envParam.scriptDir;
    local dllPath = scriptDirectory .. "ExportVSQ\\GetSaveFileName.dll";
    local luavsqPath = scriptDirectory .. "ExportVSQ\\luavsq.lua";

    if( false == pcall( dofile, luavsqPath ) )then
        VSMessageBox( "luavsq ライブラリの読み込みに失敗しました", 0 );
        return 0;
    end

    local luavsq_GetSaveFileName = package.loadlib( dllPath, "luavsq_GetSaveFileName" );
    if( nil == luavsq_GetSaveFileName )then
        VSMessageBox( "DLL 読み込みに失敗しました", 0 );
        return 0;
    end

    local path = luavsq_GetSaveFileName( "", envParam.scriptDir .. "..\\VOCALOID3.exe" );
    if( nil == path )then
        return 0;
    end

    luavsq.Sequence._WRITE_NRPN = true;

    local sequence = luavsq.Sequence.new( "", 1, 4, 4, 500000 );
    sequence.tempoList = Export.getTempoList();
    sequence.timesigList = Export.getTimesigList();

    local track = sequence.track:get( 1 );
    track:setName( Export.getMusicalPartName() );

    Export.appendSingerEvent( track );
    Export.appendNoteEvents( track );

    local controlCurves = { "DYN", "BRE", "BRI", "CLE", "GEN", "PIT", "PBS", "POR" };
    for i, curveName in pairs( controlCurves ) do
        Export.appendControlCurve( track, curveName );
    end

    Export.appendOpeningControlCurve( track );

    local fileStream = luavsq.FileOutputStream.new( path );
    sequence:write( fileStream, 500, "Shift_JIS" );
    fileStream:close();

    return 0;
end

if( nil == Export )then
    Export = {};

    ---
    -- テンポ情報テーブルを取得する
    -- @return (luavsq.TempoList)
    function Export.getTempoList()
        local tempoList = luavsq.TempoList.new();
        local tempoInfo = nil;
        local succeeded = 1;
        VSSeekToBeginTempo();
        succeeded, tempoInfo = VSGetNextTempo();
        while( succeeded ~= 0 )do
            local midiTempo = math.floor( 60e6 / tempoInfo.tempo );
            tempoList:push( luavsq.Tempo.new( tempoInfo.posTick, midiTempo ) );
            succeeded, tempoInfo = VSGetNextTempo()
        end
        tempoList:updateTempoInfo();
        return tempoList;
    end

    ---
    -- 拍子情報テーブルを取得する
    -- @return (luavsq.TimesigList)
    function Export.getTimesigList()
        local timesigList = luavsq.TimesigList.new();
        local timesigInfo = {};
        local succeeded = 1;
        VSSeekToBeginTimeSig();
        succeeded, timesigInfo = VSGetNextTimeSig();
        while( succeeded ~= 0 )do
            local clock = timesigInfo.posTick;
            local barCount = 0;
            if( clock > 0 )then
                barCount = timesigList:getBarCountFromClock( clock );
            end
            timesigList:push(
                luavsq.Timesig.new( timesigInfo.numerator, timesigInfo.denominator, barCount )
            );
            timesigList:updateTimesigInfo();
            succeeded, timesigInfo = VSGetNextTimeSig();
        end
        return timesigList;
    end

    ---
    -- 音符情報を読み込み、指定されたトラックに追加する
    -- @param (luavsq.Track) 追加先のトラック
    function Export.appendNoteEvents( track )
        local offset = Export.getMusicalPartOffset();

        VSSeekToBeginNote();
        local result, noteEx;
        result, noteEx = VSGetNextNoteEx();
        while( result ~= 0 )do
            local clock = noteEx.posTick + offset;
            local event = luavsq.Event.new( clock, luavsq.EventTypeEnum.NOTE );
            event:setLength( noteEx.durTick );
            event.note = noteEx.noteNum;
            event.dynamics = noteEx.velocity;
            event.lyricHandle = luavsq.Handle.new( luavsq.HandleTypeEnum.LYRIC );
            event.lyricHandle:setLyricAt( 0, luavsq.Lyric.new( noteEx.lyric, noteEx.phonemes ) );
            event.pmBendDepth = noteEx.bendDepth;
            event.pmBendLength = noteEx.bendLength;
            event.pmbPortamentoUse = noteEx.risePort + 2 * noteEx.fallPort;
            event.demDecGainRate = noteEx.decay;
            event.demAccent = noteEx.accent;
            if( noteEx.vibratoType ~= 0 )then
                local vibratoTickLength = math.floor( event:getLength() * noteEx.vibratoLength / 100.0 );
                event.vibratoDelay = event:getLength() - vibratoTickLength;
                event.vibratoHandle = luavsq.Handle.new( luavsq.HandleTypeEnum.VIBRATO );
                event.vibratoHandle.iconId = string.format( "$0404%04X", noteEx.vibratoType );
                event.vibratoHandle:setLength( vibratoTickLength );
            end
            track.events:add( event );

            result, noteEx = VSGetNextNoteEx();
        end
    end

    ---
    -- 歌手変更情報を読み込み、指定されたトラックに追加する
    -- @param (luavsq.Track)
    function Export.appendSingerEvent( track )
        local result, singerInfo;
        result, singerInfo = VSGetMusicalPartSinger();
        if( result ~= 1 )then
            return
        end
        local offset = Export.getMusicalPartOffset();
        local bankSelect = singerInfo.vBS;
        local programChange = singerInfo.vPC;
        local event = luavsq.Event.new( offset, luavsq.EventTypeEnum.SINGER );
        event.singerHandle = luavsq.Handle.new( luavsq.HandleTypeEnum.SINGER );
        event.language = bankSelect;
        event.program = programChange;
        event.iconId = string.format( "$0701%02X%02X", bankSelect, programChange );

        track.events:add( event );
    end

    ---
    -- トラックに、コントロールカーブのデータ点を追加する
    -- ただし、opening カーブは処理できないので、appendOpeningControlCurve メソッドを使うこと
    -- @param (luavsq.Track) track
    -- @param (string) curveName
    function Export.appendControlCurve( track, curveName )
        local offset = Export.getMusicalPartOffset();
        local target = track:getCurve( curveName );
        VSSeekToBeginControl( curveName );
        local result, control;
        result, control = VSGetNextControl( curveName );
        while( result ~= 0 )do
            target:addWithoutSort( control.posTick + offset, control.value );
            result, control = VSGetNextControl( curveName );
        end
    end

    ---
    -- トラックに opening コントロールカーブのデータ点を追加する
    -- @param (luavsq.Track)
    function Export.appendOpeningControlCurve( track )
        local offset = Export.getMusicalPartOffset();
        local target = track:getCurve( "OPE" );

        VSSeekToBeginNote();
        local result, noteEx;
        result, noteEx = VSGetNextNoteEx();
        while( result ~= 0 )do
            target:add( noteEx.posTick + offset, noteEx.opening );
            result, noteEx = VSGetNextNoteEx();
        end
    end

    ---
    -- 現在選択中の Musical Part の、曲頭からのオフセットを取得する
    -- @return (int) clock 単位のオフセット
    function Export.getMusicalPartOffset()
        local result, part;
        result, part = VSGetMusicalPart();
        if( result == 1 )then
            return part.posTick;
        else
            return 0;
        end
    end

    ---
    -- 現在選択中の Musical Part の名前を取得する
    -- @return (string)
    function Export.getMusicalPartName()
        local result, part;
        result, part = VSGetMusicalPart();
        if( result == 1 )then
            return part.name;
        else
            return "";
        end
    end
end
