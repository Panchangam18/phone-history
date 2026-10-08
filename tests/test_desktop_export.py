import base64
import importlib.util
import json
import os
import socket
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid
from unittest import mock
import hashlib

BASE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("connector", BASE / "Desktop/phone_history_agent.py")
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class DesktopExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.binary = cls.root / "protocol-check"
        subprocess.run(["xcrun", "swiftc", str(BASE / "Shared/BuildConfiguration.swift"), str(BASE / "Shared/HistoryPaths.swift"), str(BASE / "Shared/NaturalMemory.swift"), str(BASE / "Shared/ContextText.swift"), str(BASE / "Shared/HistoryReader.swift"), str(BASE / "Shared/MemoryRecord.swift"),
                        str(BASE / "Shared/DesktopAccess.swift"), str(BASE / "Shared/StoragePolicy.swift"),str(BASE / "Shared/HistoryOffload.swift"), str(BASE / "Tunnel/DesktopExportServer.swift"), str(BASE / "tests/desktop-export/main.swift"),
                        "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.fixture_archive_file = None
        self.folder = self.root / str(uuid.uuid4())
        self.folder.mkdir()
        self.state = self.folder / "client.json"
        self.request = self.folder / "request.json"
        agent.init_pair(self.state, self.request, "Test desktop")
        self.worker = subprocess.Popen([str(self.binary), str(self.folder / "phone")],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.worker.stdin.write(self.request.read_text().replace("\n", " ") + "\n")
        self.worker.stdin.flush()
        self.connection = json.loads(self.worker.stdout.readline())
        approval = self.folder / "approval.json"
        approval.write_text(json.dumps(self.connection))
        agent.pair(self.state, approval)
        self.credentials = agent.load_state(self.state)
        self.now = time.time()
        records = self.folder / "phone/Records"
        records.mkdir()
        day = int(self.now // 86400)
        seconds = int(self.now % 86400)
        (records / ("history-%s.jsonl" % day)).write_text(
            json.dumps({"v": 2, "t": day * 86400, "reset": True}) + "\n" +
            json.dumps({"s": seconds - 20, "p": 1, "a": "Fixture", "n": ["Older fixture"]}) + "\n" +
            json.dumps({"s": seconds, "p": 1, "n": ["Fixture title"]}) + "\n")
        (self.folder / "phone/status.json").write_text(json.dumps({"state": "running", "updated_at": self.now,
                                                                   "developer_private_key": "must not export"}))

    def tearDown(self):
        if self.fixture_archive_file is not None:
            self.fixture_archive_file.unlink(missing_ok=True)
            self.fixture_archive_file.parent.rmdir()
        self.worker.stdin.close()
        self.worker.wait(timeout=3)
        self.worker.stdout.close()

    def request_body(self, **changes):
        request = {"request_id": str(uuid.uuid4()), "issued_at": self.now, "operation": "history",
                   "since": self.now - 10, "limit": 1}
        request.update(changes)
        return request, agent.envelope(self.credentials, request)

    def ask(self, body, now=None):
        self.worker.stdin.write(json.dumps({"body": agent.b64(body), "now": now or self.now}) + "\n")
        self.worker.stdin.flush()
        return json.loads(self.worker.stdout.readline())

    def screenshot_permission(self, allowed):
        self.worker.stdin.write(json.dumps({"allow_screenshots":allowed})+"\n");self.worker.stdin.flush()
        self.assertEqual(json.loads(self.worker.stdout.readline()),{"updated":True})

    def memory_fixture(self):
        return {"kind":"memory","v":1,"format":8,"id":"m-fixture","scope":"10min","start":self.now-600,"end":self.now,
                "title":"Specific topic","summary":"Observed fixture content.","facts":["A visible fact"],"sources":["e-fixture"],
                "apps":["Fixture"],"partial":True,"evidenceChecked":True,"generatedAt":self.now,"model":"apple-system-language-model"}

    def append_rows(self, rows):
        file=self.folder/"phone/Records"/("history-%s.jsonl" % int(self.now//86400))
        with file.open("a") as stream:
            for row in rows:stream.write(json.dumps(row)+"\n")

    def opened(self, **fields):
        request,body=self.request_body(**fields)
        return agent.open_response(self.credentials,json.dumps(self.ask(body)).encode(),request["request_id"])

    def test_mixed_memory_rows_preserve_evidence_dictionary(self):
        seconds=int(self.now%86400)
        self.append_rows([self.memory_fixture(),{"p":1,"s":seconds,"c":[1,0],"id":"e-fixture","source":"OCR"}])
        value=self.opened(limit=5)
        self.assertEqual(value["entries"][0]["text"],["Fixture title","Older fixture"])
        self.assertEqual(value["entries"][0]["source"],"OCR")
        self.assertEqual(value["skipped_rows"],0)
        memories=self.opened(operation="memories",limit=100)
        self.assertEqual(memories["returned"],1);self.assertEqual(memories["limit"],20)
        self.assertEqual(memories["entries"][0]["sources"],["e-fixture"])
        evidence=self.opened(operation="evidence",ids=["e-fixture","m-fixture","e-expired"])
        self.assertEqual({e["id"] for e in evidence["entries"]},{"e-fixture","m-fixture"})
        self.assertEqual(evidence["missing_ids"],["e-expired"])

    def test_latest_summary_replaces_partial_window_without_losing_sources(self):
        earlier=self.memory_fixture();earlier["id"]="m-earlier";earlier["generatedAt"]=self.now-60
        newest=self.memory_fixture();newest["id"]="m-latest";newest["summary"]="The content centered on a specific topic."
        self.append_rows([earlier,newest])
        memories=self.opened(operation="memories",limit=20)
        self.assertEqual([e["id"] for e in memories["entries"]],["m-latest"])
        proof=self.opened(operation="evidence",ids=["m-earlier","m-latest"])
        self.assertEqual({e["id"] for e in proof["entries"]},{"m-earlier","m-latest"})

    def test_invalid_memory_bounds_are_skipped_without_losing_evidence(self):
        memory=self.memory_fixture();memory["summary"]="🧠"*300
        self.append_rows([memory])
        value=self.opened(operation="memories",limit=5)
        self.assertEqual(value["returned"],0);self.assertEqual(value["skipped_rows"],1)
        self.assertEqual(self.opened()["returned"],1)

    def test_archived_memory_does_not_reset_evidence_decoder(self):
        directory=self.folder/"archive"/"archives"/self.connection["pair_id"];directory.mkdir(parents=True)
        day=int(self.now//86400);seconds=int(self.now%86400)
        rows=[{"v":2,"t":day*86400},{"p":1,"s":seconds-2,"a":"Fixture","n":["Visible content"]},self.memory_fixture(),
              {"p":1,"s":seconds,"c":[0],"id":"e-ref","source":"OCR"}]
        (directory/("history-%s.jsonl" % day)).write_text("\n".join(json.dumps(r) for r in rows)+"\n")
        with mock.patch.object(agent,"ROOT",self.folder/"archive"):
            values=agent.archive_recent(self.credentials,self.now-60)
        self.assertEqual(values[0]["id"],"e-ref");self.assertEqual(values[0]["text"],["Visible content"])

    def test_evidence_input_and_memory_mcp_remain_read_only(self):
        message={"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"phone_history_evidence","arguments":{"ids":[]}}}
        self.assertTrue(agent.rpc(message,self.state)["result"]["isError"])
        message["params"]={"name":"phone_history_memories","arguments":{"limit":21}}
        self.assertTrue(agent.rpc(message,self.state)["result"]["isError"])
        self.worker.stdin.write('{"revoke":true}\n');self.worker.stdin.flush();self.worker.stdout.readline()
        _,body=self.request_body(operation="memories")
        self.assertEqual(self.ask(body),{"denied":True})

    def test_clock_only_evidence_is_hidden_but_still_resolves_by_id(self):
        seconds=int(self.now%86400)
        self.append_rows([{"p":2,"s":seconds,"n":["7:58 PM"],"id":"e-clock"}])
        value=self.opened(limit=10)
        self.assertFalse(any(e["id"]=="e-clock" for e in value["entries"]))
        proof=self.opened(operation="evidence",ids=["e-clock"])
        self.assertEqual(proof["entries"][0]["text"],["7:58 PM"])
        self.assertEqual(proof["missing_ids"],[])

    def generated(self,title,summary,evidence,content=None):
        self.worker.stdin.write(json.dumps({"draft":{"title":title,"summary":summary,"evidence":evidence},
                                          "content":content or ["Your document was saved successfully"]})+"\n")
        self.worker.stdin.flush()
        return json.loads(self.worker.stdout.readline())

    def test_model_prose_is_preserved_without_coded_verb_or_sentence_templates(self):
        summary="You finished editing the proposal and saved it."
        value=self.generated("Proposal saved",summary,[{"excerpt":1,"quote":"saved successfully"}])
        self.assertTrue(value["accepted"])
        self.assertEqual(value["summary"],summary)
        self.assertEqual(value["title"],"Proposal saved")
        self.assertEqual(value["quotes"],["saved successfully"])
        self.assertIn("1970-01-01T00:16:40Z",value["prompt"])

    def test_grounding_requires_every_quote_and_its_own_excerpt_to_exist(self):
        good={"excerpt":1,"quote":"saved successfully"}
        for bad in [{"excerpt":999,"quote":"saved successfully"},{"excerpt":1,"quote":"published successfully"},
                    {"excerpt":1,"quote":""}]:
            self.assertFalse(self.generated("Saved","Model-authored prose.",[good,bad])["accepted"])
        self.assertFalse(self.generated("Saved","Model-authored prose.",[])["accepted"])

    def test_prose_and_support_byte_limits_do_not_silently_truncate_claims(self):
        good=[{"excerpt":1,"quote":"saved successfully"}]
        self.assertFalse(self.generated("💡"*41,"A summary.",good)["accepted"])
        self.assertFalse(self.generated("Saved","💡"*251,good)["accepted"])
        self.assertFalse(self.generated("Saved","",good)["accepted"])
        self.assertFalse(self.generated("Saved","A summary.",[{"excerpt":1,"quote":"a"*241}],content=["a"*300])["accepted"])
        self.assertFalse(self.generated("Saved","A summary.",good*5)["accepted"])

    def test_quote_check_does_not_claim_to_verify_semantic_interpretations(self):
        # Generation instructions enforce semantics; this gate only verifies
        # copied evidence. It cannot validate an action or a named pattern.
        prose="The model's interpretation is unchanged by quote validation."
        self.assertEqual(self.generated("Interpretation",prose,[{"excerpt":1,"quote":"saved successfully"}])["summary"],prose)

    def test_model_line_references_copy_source_quotes_and_reject_missing_ids(self):
        good={"excerpt":1,"line":1}
        for refs,accepted in [([good],True),([{"excerpt":999,"line":1}],False),
                              ([good,{"excerpt":1,"line":999}],False),([],False)]:
            self.worker.stdin.write(json.dumps({"line_references":refs})+"\n");self.worker.stdin.flush()
            value=json.loads(self.worker.stdout.readline())
            self.assertEqual(value["accepted"],accepted)
            if accepted:
                self.assertEqual(value["summary"],"You saved the document.")
                self.assertEqual(value["quotes"],["Your document was saved successfully"])

    def test_model_abstention_supersedes_old_memory_without_deleting_evidence(self):
        memory=self.memory_fixture();memory["format"]=14
        self.append_rows([memory])
        (self.folder/"phone/memory-cursor.json").write_text(json.dumps({"format_revision":16,
            "abstained_10min_"+str(int(memory["start"])):memory["end"]}))
        self.assertEqual(self.opened(operation="memories")["returned"],0)
        proof=self.opened(operation="evidence",ids=[memory["id"]])
        self.assertEqual(proof["missing_ids"],[])
        self.assertEqual(proof["entries"][0]["id"],memory["id"])

    def test_generation_diagnostics_expose_codes_without_private_drafts_or_errors(self):
        (self.folder/"phone/memory-status.json").write_text(json.dumps({"state":"deferred","generation_failure":"context_limit",
            "reason":"private model error", "candidate_summary":"private prose", "prompt":"private content"}))
        result=self.opened(operation="status")["memory_generation"]
        self.assertEqual(result,{"state":"deferred","generation_failure":"context_limit"})

    def test_backup_exclusion_preserves_existing_history_and_is_idempotent(self):
        self.worker.stdin.write('{"backup_policy":true}\n');self.worker.stdin.flush()
        value=json.loads(self.worker.stdout.readline())
        self.assertTrue(value["excluded"])
        self.assertEqual(value["retained"],"retained fixture")

    def test_new_memory_format_replaces_old_window_and_keeps_original_by_id(self):
        old=self.memory_fixture();old["id"]="m-old-specificity"
        new=self.memory_fixture();new["id"]="m-new-specificity";new["format"]=14;new["generatedAt"]=self.now+1
        new["summary"]="You reviewed the Lumen Pocket launch and its offline model support."
        self.append_rows([old,new])
        self.assertEqual([row["id"] for row in self.opened(operation="memories")["entries"]],[new["id"]])
        proof=self.opened(operation="evidence",ids=[old["id"],new["id"]])
        self.assertEqual(proof["missing_ids"],[])

    def test_screenshot_permission_rate_limit_and_revocation(self):
        request,body=self.request_body(operation="screenshot")
        self.assertEqual(self.ask(body),{"denied":True})
        self.screenshot_permission(True)
        response=agent.open_response(self.credentials,json.dumps(self.ask(body)).encode(),request["request_id"])
        content=agent.screenshot_content(response)
        self.assertEqual(content[1]["type"],"image");self.assertEqual(content[1]["mimeType"],"image/jpeg")
        self.assertNotIn("data",json.loads(content[0]["text"].split("\n",1)[1]))
        self.assertFalse(response["screenshot"]["stored"])
        self.assertEqual(self.ask(body),{"denied":True})
        _,again=self.request_body(operation="screenshot")
        self.assertEqual(self.ask(again),{"denied":True})
        self.now+=31
        self.worker.stdin.write('{"recreate":true}\n');self.worker.stdin.flush();self.worker.stdout.readline()
        request,body=self.request_body(operation="screenshot")
        self.assertTrue(agent.open_response(self.credentials,json.dumps(self.ask(body)).encode(),request["request_id"])["screenshot"]["available"])
        self.screenshot_permission(False);self.now+=31
        _,body=self.request_body(operation="screenshot")
        self.assertEqual(self.ask(body),{"denied":True})

    def test_manual_summary_is_authenticated_rate_limited_and_revocable(self):
        request,body=self.request_body(operation="summarize")
        result=agent.open_response(self.credentials,json.dumps(self.ask(body)).encode(),request["request_id"])
        self.assertTrue(result["summary_request"]["queued"])
        self.assertEqual(result["summary_request"]["window_seconds"],600)
        self.assertEqual(self.ask(body),{"denied":True})
        _,body=self.request_body(operation="summarize")
        self.assertEqual(self.ask(body),{"denied":True})
        self.now+=61
        self.worker.stdin.write('{"recreate":true}\n');self.worker.stdin.flush();self.worker.stdout.readline()
        request,body=self.request_body(operation="summarize")
        self.assertTrue(agent.open_response(self.credentials,json.dumps(self.ask(body)).encode(),request["request_id"])["summary_request"]["queued"])
        self.worker.stdin.write('{"revoke":true}\n');self.worker.stdin.flush();self.worker.stdout.readline()
        self.now+=61
        _,body=self.request_body(operation="summarize")
        self.assertEqual(self.ask(body),{"denied":True})

    def test_legacy_desktop_permissions_do_not_grant_screenshots(self):
        path=self.folder/"phone/desktop-access.json";value=json.loads(path.read_text())
        for pair in value["pairs"]: pair.pop("allowsScreenshots",None)
        path.write_text(json.dumps(value))
        _,body=self.request_body(operation="screenshot")
        self.assertEqual(self.ask(body),{"denied":True})
        request,body=self.request_body()
        self.assertEqual(agent.open_response(self.credentials,json.dumps(self.ask(body)).encode(),request["request_id"])["returned"],1)

    def test_screenshot_mcp_image_and_unavailable_errors(self):
        value={"screenshot":{"available":True,"mime_type":"image/jpeg","width":100,"height":200,"stored":False,"data":agent.b64(bytes([255,216,255,217]))}}
        message={"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"phone_history_screenshot","arguments":{}}}
        with mock.patch.object(agent,"fetch",return_value=value) as fetch:
            result=agent.rpc(message,self.state)["result"]
        self.assertFalse(result["isError"]);self.assertEqual(result["content"][1]["type"],"image")
        self.assertEqual(fetch.call_args.args[1],"screenshot")
        value["screenshot"]["data"]=agent.b64(b"invalid")
        with self.assertRaisesRegex(ValueError,"image"):agent.screenshot_content(value)
        with mock.patch.object(agent,"fetch",return_value={"screenshot":{"available":False,"reason":"locked"}}):
            result=agent.rpc(message,self.state)["result"]
        self.assertTrue(result["isError"]);self.assertNotIn("image",str(result))
        value["screenshot"]["data"]="A"*1_400_004
        with self.assertRaisesRegex(ValueError,"response"):agent.screenshot_content(value)

    def test_agents_can_read_acknowledged_archives_when_phone_offline(self):
        directory=self.folder/"local-archive"/"archives"/self.connection["pair_id"];directory.mkdir(parents=True)
        day=int(self.now//86400);seconds=int(self.now%86400)
        (directory/("history-%s-123-%s.jsonl" % (day,str(uuid.uuid4())))).write_text(
            json.dumps({"v":2,"t":day*86400})+"\n"+json.dumps({"p":1,"s":seconds-2,"a":"Fixture","n":["First memory"]})+"\n"+json.dumps({"p":1,"s":seconds,"n":["New memory"],"c":[1,0]})+"\n")
        with mock.patch.object(agent,"ROOT",self.folder/"local-archive"),mock.patch.object(agent,"fetch",side_effect=OSError("offline")):
            value=agent.recent(self.state,minutes=60,limit=1)
        self.assertFalse(value["phone_available"]);self.assertEqual(value["entries"][0]["text"],["New memory","First memory"])
        self.assertTrue(value["content_is_untrusted"]);self.assertEqual(value["sources"],["desktop archive"])

    def test_connected_only_read_never_opens_archives_after_phone_failure(self):
        with mock.patch.object(agent,"fetch",side_effect=OSError("offline")), mock.patch.object(agent,"archive_recent",return_value=[{"text":["Local memory"]}]) as archives:
            with self.assertRaisesRegex(ConnectionError,"Live connection"):
                agent.recent(self.state,minutes=60,limit=1,require_phone=True)
            archives.assert_not_called()

    def test_mcp_connected_only_read_rejects_offline_fallback(self):
        request={"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"phone_history_recent","arguments":{"require_phone":True}}}
        with mock.patch.object(agent,"fetch",side_effect=OSError("offline")),mock.patch.object(agent,"archive_recent") as archives:
            value=agent.rpc(request,self.state)["result"]
            self.assertTrue(value["isError"])
            self.assertIn("Live connection",value["content"][0]["text"])
            archives.assert_not_called()

    def test_connected_only_read_marks_authenticated_response_live(self):
        with mock.patch.object(agent,"fetch",return_value={"schema":1,"entries":[]}),mock.patch.object(agent,"archive_recent",return_value=[]):
            value=agent.recent(self.state,require_phone=True)
        self.assertTrue(value["phone_available"])
        with self.assertRaises(ValueError):agent.recent(self.state,require_phone="false")

    def test_skill_runner_unpaired_and_read_only_commands(self):
        runner=BASE/"Desktop/skills/phone-history/scripts/read_phone.py"
        unpaired=subprocess.run([os.sys.executable,str(runner),"status","--state",str(self.folder/"missing.json")],text=True,capture_output=True)
        self.assertEqual(unpaired.returncode,1)
        self.assertIn("Pair this desktop first",unpaired.stderr)
        removal=subprocess.run([os.sys.executable,str(runner),"receive"],text=True,capture_output=True)
        self.assertEqual(removal.returncode,2)
        self.assertIn("invalid choice",removal.stderr)

    def test_active_receiver_requires_live_server_lease_and_approval(self):
        self.offload_request("receiver_poll")
        def active(now):
            self.worker.stdin.write(json.dumps({"active_receiver":True,"now":now})+"\n");self.worker.stdin.flush()
            return json.loads(self.worker.stdout.readline())["active"]
        self.assertFalse(active(self.now))
        status=self.folder/"phone/desktop-server.json";status.write_text(json.dumps({"state":"ready"}))
        self.assertTrue(active(self.now));self.assertFalse(active(self.now+91))
        status.write_text(json.dumps({"state":"unavailable"}));self.assertFalse(active(self.now))
        status.write_text(json.dumps({"state":"ready"}));self.worker.stdin.write(json.dumps({"revoke":True})+"\n");self.worker.stdin.flush();self.worker.stdout.readline()
        self.assertFalse(active(self.now))

    def offload_fixture(self):
        records=self.folder/"phone/Records"
        name="history-%s-123-%s.jsonl" % (int(self.now//86400),str(uuid.uuid4()))
        content=(json.dumps({"v":2,"t":int(self.now//86400)*86400})+"\n"+json.dumps({"s":1,"p":1,"n":["A saved context"]})+"\n").encode()*1000
        file=records/name;file.write_bytes(content)
        (self.folder/"phone/storage-settings.json").write_text(json.dumps({"mode":"send","days":7,"receiverID":self.connection["pair_id"]}))
        return file,content

    def offload_request(self, operation, **fields):
        request,body=self.request_body(operation=operation,**fields)
        result=self.ask(body)
        if result.get("denied"):raise ValueError("Denied")
        return agent.open_response(self.credentials,json.dumps(result).encode(),request["request_id"])

    def test_offload_requires_selection_and_never_removes_active_file(self):
        ready=self.offload_request("receiver_poll")
        self.assertFalse(ready["offload_selected"])
        file,content=self.offload_fixture()
        active=self.folder/"phone/Records"/("history-%s.jsonl" % int(self.now//86400))
        with self.assertRaises(ValueError):self.offload_request("offload_ack",name=active.name,sha256=hashlib.sha256(active.read_bytes()).hexdigest())
        self.assertTrue(active.exists())
        self.assertEqual(self.offload_request("receiver_poll")["segment"]["name"],file.name)
        with self.assertRaises(ValueError):self.offload_request("offload_ack",name=file.name,sha256="0"*64)
        self.assertEqual(file.read_bytes(),content)

    def test_durable_receiver_save_then_ack_and_disconnect_recovery(self):
        file,content=self.offload_fixture();archive=self.folder/"archive"
        real=self.offload_request
        def fail_ack(path,operation,host=None,**fields):
            if operation == "offload_ack":raise ValueError("Disconnected before acknowledgment")
            return real(operation,**fields)
        with mock.patch.object(agent,"receiver_request",side_effect=fail_ack):
            with self.assertRaises(ValueError):agent.receive_once(self.state,archive_root=archive)
        self.assertTrue(file.exists())
        destination=archive/self.connection["pair_id"]/file.name
        self.assertEqual(destination.read_bytes(),content)
        with mock.patch.object(agent,"receiver_request",side_effect=lambda path,operation,host=None,**fields:real(operation,**fields)):
            result=agent.receive_once(self.state,archive_root=archive)
        self.assertTrue(result["phone_copy_removed"]);self.assertFalse(file.exists());self.assertEqual(destination.read_bytes(),content)
        self.assertEqual(destination.stat().st_mode & 0o777,0o600)

    def test_offload_denied_after_policy_change(self):
        file,_=self.offload_fixture()
        self.offload_request("receiver_poll")
        (self.folder/"phone/storage-settings.json").write_text(json.dumps({"mode":"none","days":7}))
        with self.assertRaises(ValueError):self.offload_request("offload_ack",name=file.name,sha256=hashlib.sha256(file.read_bytes()).hexdigest())
        self.assertTrue(file.exists())

    def test_swift_python_encryption_and_bounded_history(self):
        request, body = self.request_body()
        result = self.ask(body)
        self.assertNotIn("Fixture", json.dumps(result))
        opened = agent.open_response(self.credentials, json.dumps(result).encode(), request["request_id"])
        self.assertEqual(opened["entries"][0]["text"], ["Fixture title"])
        self.assertEqual(opened["returned"], 1)
        self.assertNotIn("developer_private_key", opened["capture"])
        self.assertTrue(opened["content_is_untrusted"])

    def test_replay_and_rate_limit(self):
        _, body = self.request_body()
        self.assertIn("sealed", self.ask(body))
        self.assertTrue(self.ask(body)["denied"])
        _, another = self.request_body()
        self.assertTrue(self.ask(another)["denied"])

    def test_status_does_not_block_subsequent_history(self):
        status, body = self.request_body(operation="status")
        response = self.ask(body)
        opened = agent.open_response(self.credentials, json.dumps(response).encode(), status["request_id"])
        self.assertNotIn("entries", opened)
        _, body = self.request_body()
        self.assertIn("sealed", self.ask(body))

    def test_expired_request(self):
        _, body = self.request_body(issued_at=self.now - 61)
        self.assertTrue(self.ask(body)["denied"])

    def test_tampering_and_unknown_desktop(self):
        _, body = self.request_body()
        envelope = json.loads(body)
        encrypted = bytearray(agent.unb64(envelope["sealed"]))
        encrypted[-1] ^= 1
        envelope["sealed"] = agent.b64(encrypted)
        self.assertTrue(self.ask(json.dumps(envelope).encode())["denied"])
        envelope["pair_id"] = str(uuid.uuid4())
        self.assertTrue(self.ask(json.dumps(envelope).encode())["denied"])

    def test_revocation(self):
        self.worker.stdin.write('{"revoke":true}\n')
        self.worker.stdin.flush()
        self.assertTrue(json.loads(self.worker.stdout.readline())["revoked"])
        _, body = self.request_body()
        self.assertTrue(self.ask(body)["denied"])

    def test_response_bound_to_request(self):
        request, body = self.request_body()
        response = self.ask(body)
        with self.assertRaises(ValueError):
            agent.open_response(self.credentials, json.dumps(response).encode(), str(uuid.uuid4()))

    def test_private_credentials_and_public_host_rejection(self):
        os.chmod(self.state, 0o644)
        with self.assertRaises(ValueError):
            agent.load_state(self.state)
        for host in ["8.8.8.8", "127.0.0.1", "example.com", "::1"]:
            with self.assertRaises(ValueError):
                agent.validate_host(host)

    def test_replay_and_ax_rate_limit_survive_protocol_recreation(self):
        request={"request_id":str(uuid.uuid4()),"issued_at":self.now,"operation":"ax_check"}
        body=agent.envelope(self.credentials,request)
        result=self.ask(body,self.now)
        self.assertIn("ax_check",agent.open_response(self.credentials,json.dumps(result).encode(),request["request_id"]))
        self.worker.stdin.write(json.dumps({"recreate":True})+"\n");self.worker.stdin.flush()
        self.assertTrue(json.loads(self.worker.stdout.readline())["recreated"])
        self.assertTrue(self.ask(body,self.now)["denied"])
        request["request_id"]=str(uuid.uuid4());request["issued_at"]=self.now+5
        self.assertTrue(self.ask(agent.envelope(self.credentials,request),self.now+5)["denied"])
        request["request_id"]=str(uuid.uuid4());request["issued_at"]=self.now+31
        self.assertNotIn("denied",self.ask(agent.envelope(self.credentials,request),self.now+31))

    def test_mcp_handshake_and_tools(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "unknown"}}]
        run = subprocess.run([os.sys.executable, str(BASE / "Desktop/phone_history_agent.py"), "mcp"],
                             input="\n".join(json.dumps(row) for row in messages), text=True, capture_output=True, check=True)
        responses = [json.loads(line) for line in run.stdout.splitlines()]
        self.assertEqual(len(responses), 3)
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(len(responses[1]["result"]["tools"]), 6)
        self.assertTrue(all(tool["annotations"]["readOnlyHint"] for tool in responses[1]["result"]["tools"]))
        self.assertEqual(responses[2]["error"]["code"], -32602)

    def test_real_network_listener_and_client(self):
        run = subprocess.run(["ipconfig", "getifaddr", "en0"], text=True, capture_output=True)
        if run.returncode != 0:
            self.skipTest("Wi-Fi interface unavailable")
        host = run.stdout.strip()
        agent.validate_host(host)
        folder = self.folder / "network-phone"
        server = subprocess.Popen([str(self.binary), str(folder), "--server"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            server.stdin.write(self.request.read_text().replace("\n", " ") + "\n")
            server.stdin.flush()
            connection = json.loads(server.stdout.readline())
            connection["host"] = host
            approval = self.folder / "network-approval.json"
            approval.write_text(json.dumps(connection))
            agent.pair(self.state, approval)
            for _ in range(30):
                if (folder / "desktop-server.json").exists():
                    break
                time.sleep(0.1)
            self.assertEqual(json.loads((folder / "desktop-server.json").read_text())["state"], "ready")
            self.assertEqual(agent.fetch(self.state, operation="status")["schema"], 1)
            runner=BASE/"Desktop/skills/phone-history/scripts/read_phone.py"
            # Exercise the actual skill subprocess over encrypted TCP, not a
            # patched fetch. Only synthetic fixture keys/text are involved.
            live=subprocess.run([os.sys.executable,str(runner),"history","--state",str(self.state),"--minutes","60","--limit","5"],text=True,capture_output=True,check=True)
            self.assertTrue(json.loads(live.stdout)["phone_available"])
            archive=agent.ROOT/"archives"/connection["pair_id"]
            self.assertFalse(archive.exists())
            archive.mkdir(parents=True,mode=0o700)
            day=int(time.time()//86400);seconds=int(time.time()%86400)
            self.fixture_archive_file=archive/("history-%s.jsonl" % day)
            self.fixture_archive_file.write_text(json.dumps({"v":2,"t":day*86400})+"\n"+json.dumps({"p":1,"s":seconds,"a":"Fixture","n":["Offline archive must not escape"]})+"\n")
            records=folder/"Records";records.mkdir()
            name="history-%s-123-%s.jsonl" % (int(time.time()//86400),str(uuid.uuid4()))
            data=(json.dumps({"v":2,"t":int(time.time()//86400)*86400})+"\n"+json.dumps({"s":1,"p":1,"n":["Archive fixture"]})+"\n").encode()
            (records/name).write_bytes(data)
            (folder/"storage-settings.json").write_text(json.dumps({"mode":"send","days":7,"receiverID":connection["pair_id"]}))
            result=agent.receive_once(self.state,archive_root=self.folder/"network-archive")
            self.assertTrue(result["phone_copy_removed"])
            self.assertEqual(Path(result["saved_to"]).read_bytes(),data)
            self.assertFalse((records/name).exists())
            server.terminate();server.wait(timeout=3)
            disconnected=subprocess.run([os.sys.executable,str(runner),"history","--state",str(self.state)],text=True,capture_output=True)
            self.assertEqual(disconnected.returncode,1)
            self.assertIn("Live connection",disconnected.stderr)
            self.assertNotIn("Offline archive must not escape",disconnected.stdout+disconnected.stderr)
            # Restart this disposable fixture to retain the listener bounds check.
            server.stdin.close();server.stdout.close()
            server=subprocess.Popen([str(self.binary),str(folder),"--server"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
            server.stdin.write(self.request.read_text().replace("\n"," ")+"\n");server.stdin.flush();server.stdout.readline()
            for _ in range(30):
                try:
                    probe=socket.create_connection((host,9876),timeout=0.1);probe.close();break
                except OSError:time.sleep(0.1)
            connection = socket.create_connection((host, 9876), timeout=3)
            connection.sendall(b"POST /v1/export HTTP/1.1\r\nContent-Length: 999999\r\n\r\n")
            self.assertIn(b"400", connection.recv(1024))
            connection.close()
        finally:
            server.terminate(); server.wait(timeout=3)
            server.stdin.close(); server.stdout.close()


if __name__ == "__main__":
    unittest.main()
