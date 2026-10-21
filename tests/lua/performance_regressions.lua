-- SPDX-License-Identifier: Unlicense
return function(context)
    local test, equal, contains = context.test, context.assertEqual, context.assertContains
    local Settings, Bridge, entity = context.Settings, context.Bridge, context.entity

    local function harness(host)
        local h = {files={}, callbacks={}, events={}, timers={}, logs={}, ready=true,
            scans=0, actionReads=0, clientReads=0, writes=0, gets={}, revision=0, failWrites=false}
        h.actors, h.specialists, h.targets, h.rolls = {}, {}, {}, {}
        local entities = {}
        local function make(id)
            local guid = string.format("42000000-0000-0000-0000-%012d", id)
            local value = entity(guid, string.format("01c000010000%04x", id))
            entities[guid] = value
            return value
        end
        for i=1,2 do
            h.actors[i], h.specialists[i], h.targets[i] = make(i), make(i+10), make(i+20)
            h.targets[i].GetNetId = function() return i+70 end
            local roll = make(i+30)
            roll.RequestedRoll = {RollContext=6, RollUuid=roll.guid,
                Roller=h.actors[i], Subject=h.targets[i]}
            h.rolls[i] = roll
        end
        Ext = {IO={LoadFile=function(path)
                if path=="BestOfHandsNative.actions" then h.actionReads=h.actionReads+1 end
                if path=="BestOfHandsNative.client" then h.clientReads=h.clientReads+1 end
                return h.files[path]
            end, SaveFile=function(path,text)
                h.writes=h.writes+1
                if h.failWrites then return false end
                h.files[path]=text
                return true
            end}, Utils={Print=function(line) h.logs[#h.logs+1]=line end},
            Net={IsHost=function() return host==true end},
            Timer={WaitFor=function(_,cb) h.timers[#h.timers+1]=cb end},
            Events={SessionLoaded={Subscribe=function(_,cb) h.events.loaded=cb end},
                ResetCompleted={Subscribe=function(_,cb) h.events.reset=cb end}},
            Entity={Get=function(value)
                    local key=tostring(value); h.gets[key]=(h.gets[key] or 0)+1
                    return type(value)=="table" and value or entities[value]
                end, UuidToHandle=function(guid) return entities[guid] end,
                GetAllEntitiesWithComponent=function(name)
                    equal("RequestedRoll",name,"only roll bootstrap scans")
                    h.scans=h.scans+1
                    return h.rolls
                end, OnCreate=function(name,cb) h.callbacks[name.."Create"]=cb end,
                OnChange=function(name,cb) h.callbacks[name.."Change"]=cb end,
                OnDestroy=function(name,cb) h.callbacks[name.."Destroy"]=cb end}}
        local channel={SetHandler=function(_,cb) h.handler=cb end, SendToServer=function() end}
        local quick={SetHandler=function(_,cb) h.quick=cb end, SendToServer=function() return true end}
        h.bridge=Bridge.Start(Settings,quick,nil,
            {GetSession=function() return h.ready and "local-process" or "" end,
                Subscribe=function(cb) h.sessionChanged=cb end},channel)
        function h.record(i, advantage, specialist)
            return {id=i, action="lockpick", rollUuid=h.rolls[i].guid,
                initiatorUuid=h.actors[i].guid, specialistUuid=(specialist or h.specialists[i]).guid,
                targetUuid=h.targets[i].guid, presentationAdvantage=advantage or 0}
        end
        function h.send(records, options)
            options=options or {}; h.revision=h.revision+1
            h.handler({protocol="9",version=Settings.VERSION,probe=options.probe or "world-one",
                revision=options.revision or h.revision,trace=options.trace or false,records=records})
        end
        function h.text() return h.files["BestOfHandsNative.client"] or "" end
        function h.clearCounts() h.scans,h.actionReads,h.clientReads,h.writes,h.gets=0,0,0,0,{} end
        function h.rollGets(i) return h.gets[tostring(h.rolls[i])] or 0 end
        return h
    end

    test("incremental sync skips discarded host reads and identical update work",function()
        local h=harness()
        h.send({h.record(1),h.record(2)})
        equal(1,h.scans,"one bootstrap scan")
        equal(0,h.actionReads,"guest never reads a host action file")
        h.clearCounts()
        for _=1,100 do h.send({h.record(1),h.record(2)}) end
        equal(0,h.scans,"identical updates perform no full scan")
        equal(0,h.rollGets(1)+h.rollGets(2),"identical updates do not resolve roll entities")
        equal(0,h.writes,"identical updates do not rewrite client output")
        equal(0,h.actionReads,"network data requires no discarded action-file read")
        equal(100,h.clientReads,"event-time storage confirmation retains repair behavior")
        print("PERF client identical updates=100 full_scans=0 roll_lookups=0 writes=0 action_reads=0 client_repair_reads=100")
    end)

    test("incremental sync remaps affected rolls and preserves unrelated and quick requests",function()
        local h=harness()
        h.send({h.record(1),h.record(2)})
        h.quick({operation="start",request="pending-quick",actor=h.actors[2].guid,target=h.targets[2].guid})
        contains(h.text(),"quick=pending-quick","accepted quick request exists")
        h.clearCounts()
        h.send({h.record(1,1),h.record(2)})
        equal(0,h.scans,"advantage update does not enumerate engine rolls")
        equal(1,h.rollGets(1),"affected roll resolved once")
        equal(0,h.rollGets(2),"unrelated roll is untouched")
        equal(1,h.writes,"one changed output, no final duplicate write")
        contains(h.text(),"\tlockpick\t1","new advantage published")
        contains(h.text(),"record=2\t","unrelated mapping remains")
        contains(h.text(),"quick=pending-quick","accepted quick request remains")
        print("PERF client advantage update full_scans=0 affected_roll_lookups=1 unrelated_roll_lookups=0 writes=1")
        h.send({h.record(1,1,h.specialists[2]),h.record(2)})
        contains(h.text(),"record=1\t"..h.rolls[1].guid.."\t"..h.actors[1].handle
            .."\t"..h.specialists[2].handle,"same UUID specialist replacement resolves fresh handle")
    end)

    test("roll observations support metadata arriving late and reject destroyed rolls",function()
        local h=harness()
        h.send({})
        h.callbacks.RequestedRollCreate(h.rolls[1],nil,h.rolls[1].RequestedRoll)
        h.clearCounts()
        h.send({h.record(1)})
        equal(0,h.scans,"late metadata uses observed roll cache")
        contains(h.text(),"record=1\t","late metadata remaps existing observed roll")
        local component=h.rolls[1].RequestedRoll
        h.rolls[1].RequestedRoll=nil
        h.callbacks.RequestedRollDestroy(h.rolls[1],nil,component)
        h.send({}); h.send({h.record(1)})
        equal(nil,h.text():find("record=1",1,true),"destroyed roll cannot be resurrected")
    end)

    test("equal client output repairs missing or replaced files without a rescan",function()
        local h=harness()
        h.send({h.record(1)})
        local expected=h.text()
        h.files["BestOfHandsNative.client"]=nil
        h.clearCounts(); h.send({h.record(1)})
        equal(expected,h.text(),"missing file repaired")
        equal(1,h.writes,"one repair write")
        equal(0,h.scans,"repair reuses verified mappings")
        h.files["BestOfHandsNative.client"]="replaced"
        h.send({h.record(1)})
        equal(expected,h.text(),"replaced file repaired")
    end)

    test("failed client writes remain retryable even when metadata becomes identical",function()
        local h=harness()
        h.send({h.record(1)})
        h.failWrites=true; h.send({h.record(1,1)})
        equal(1,#h.timers,"one recovery timer despite multiple failed save attempts")
        h.failWrites=false; h.send({h.record(1,1)})
        contains(h.text(),"\tlockpick\t1","same metadata retries failed publication")
        h.files["BestOfHandsNative.client"]=nil
        h.timers[1]()
        contains(h.text(),"\tlockpick\t1","scheduled retry forces publication")
    end)

    test("client full recovery preserves generations and remaps after local readiness",function()
        local h=harness()
        h.ready=false; h.send({h.record(1)})
        equal(0,h.scans,"no scan before local native readiness")
        equal(0,h.actionReads,"unready local session does not read host files")
        h.ready=true; h.sessionChanged()
        contains(h.text(),"record=1\t","readiness remaps metadata delivered earlier")
        h.clearCounts(); h.send({h.record(1)}, {probe="world-two"})
        equal(1,h.scans,"new probe forces full discovery")
        local expected=h.text()
        h.send({}, {probe="world-two",revision=1})
        equal(expected,h.text(),"stale revision cannot remove current mapping")
        h.events.reset(); h.clearCounts()
        h.send({h.record(1)}, {probe="world-two",revision=1})
        equal(1,h.scans,"reset accepts fresh source and rescans even with reused probe")
    end)

    test("trace changes publish a header without remapping unrelated client rolls",function()
        local h=harness()
        h.send({h.record(1)})
        h.clearCounts(); h.send({h.record(1)},{trace=true})
        equal(0,h.scans,"trace toggle does not rescan")
        equal(0,h.rollGets(1),"trace toggle does not remap")
        contains(h.text(),"trace=1","trace state still reaches native document")
        equal(1,h.writes,"trace header change is published")
    end)

    test("host action-file fallback remains available until network data is present",function()
        local h=harness(true)
        h.files["BestOfHandsNative.actions"]=table.concat({"protocol=9","pak_version="..Settings.VERSION,
            "probe=world-one","native_session=local-process","trace=0",
            table.concat({"record=1","lockpick","0","0","0","0","0",h.rolls[1].guid,
                h.actors[1].guid,h.specialists[1].guid,h.targets[1].guid,"0"},"\t"),"end=1",""},"\n")
        h.bridge.GetRecord(h.rolls[1],h.rolls[1].RequestedRoll)
        equal(1,h.actionReads,"host fallback reads authoritative file")
        h.clearCounts(); h.send({h.record(1)})
        equal(0,h.actionReads,"host uses network data without a speculative file read")
    end)

    test("server duplicate writes are skipped while storage repair and network resend remain",function()
        local bridge,files,queue,_,ack,snapshots=context.regressionBridge(1)
        local originalSave=Ext.IO.SaveFile
        local writes=0
        Ext.IO.SaveFile=function(...) writes=writes+1; return originalSave(...) end
        bridge.BeginHandshake(); ack(); queue[1]()
        local previousWrites,previousSnapshots=writes,#snapshots
        bridge.SetTrace(false); bridge.SetTrace(false)
        equal(previousWrites,writes,"equal server payload is not rewritten")
        equal(previousSnapshots+2,#snapshots,"network resend semantics retained")
        local expected=files["BestOfHandsNative.actions"]
        files["BestOfHandsNative.actions"]=nil
        bridge.SetTrace(false)
        equal(expected,files["BestOfHandsNative.actions"],"equal server payload repairs missing file")
        equal(previousWrites+1,writes,"one server repair write")
    end)
end
