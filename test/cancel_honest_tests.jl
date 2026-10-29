using ReTest
using Kaimon
using Kaimon.Database

# ── cancel_eval honesty ──────────────────────────────────────────────────────
# Regression: cancel_eval used to write status='cancelled' (plus finished_at)
# at REQUEST time — before the eval had stopped. A job whose code never
# observed is_cancelled() stayed 'cancelled' in the DB forever while still
# burning CPU, and a job that later finished normally had its row rewritten to
# 'completed'. The fix records the request without ending the job: status stays
# 'running' (so restart reconciliation still finds the row and no consumer has
# to learn a new status), `cancelled` + `cancel_requested_at` carry the request,
# check_eval reports it as pending, and the collector writes the terminal
# 'cancelled' (with the result) only when the code actually stops.

const _CANCEL_TEST_CODE = "for i in 1:10^9; KaimonGate.is_cancelled() && break; end"

function _cancel_test_fixture(eval_id::String; status::Symbol = :promoted)
    Database.init_db!(tempname() * ".db")
    mgr = Kaimon.ConnectionManager(sock_dir = tempdir())
    Database.persist_job!(eval_id, "sess1234", _CANCEL_TEST_CODE, time(), time())
    rec = Kaimon.EvalRecord(eval_id, "sess1234", _CANCEL_TEST_CODE,
                            time(), 0.0, 0.0, time(), status, "", "", true,
                            Dict{String, String}())
    push!(mgr.eval_history, rec)
    mgr, rec
end

function with_conn_mgr(f::Function, mgr)
    old = Kaimon.GATE_CONN_MGR[]
    Kaimon.GATE_CONN_MGR[] = mgr
    try
        f()
    finally
        Kaimon.GATE_CONN_MGR[] = old
    end
end

@testset "cancel_eval marks the request, not the result" begin
    eval_id = "cafe0001"
    mgr, rec = _cancel_test_fixture(eval_id)
    with_conn_mgr(mgr) do
        # No REPLConnection exists for the session, so the :cancel_job notify is
        # skipped — this tests the record + DB transition.
        resp = Kaimon.cancel_eval_tool.handler(Dict("eval_id" => eval_id))

        @test rec.cancel_requested_at > 0.0
        @test rec.status == :promoted          # not ended by the request
        @test rec.finished_at == 0.0           # the job has NOT finished
        @test occursin("Cancellation requested", string(resp))

        job = Database.get_job(eval_id)
        @test job !== nothing
        @test job["status"] == "running"       # still reconcilable after a restart
        @test job["cancelled"] == 1
        @test job["cancel_requested_at"] > 0.0
        @test job["finished_at"] == 0.0        # not stamped at request time
        # A pending request is not a cancelled job: stats count only stopped rows.
        @test Database.get_job_stats()["cancelled"] == 0
    end
end

@testset "check_eval reports a pending cancel request" begin
    eval_id = "cafe0002"
    mgr, rec = _cancel_test_fixture(eval_id)
    with_conn_mgr(mgr) do
        Kaimon.cancel_eval_tool.handler(Dict("eval_id" => eval_id))
        resp = string(Kaimon.check_eval_tool.handler(Dict("eval_id" => eval_id)))
        @test occursin("running", resp)
        @test occursin("cancel requested", resp)
    end
end

@testset "check_eval reports it from the DB for a previous session" begin
    eval_id = "cafe0003"
    mgr, _ = _cancel_test_fixture(eval_id)   # in-memory record dropped below
    empty!(mgr.eval_history)
    with_conn_mgr(mgr) do
        Kaimon.cancel_eval_tool.handler(Dict("eval_id" => eval_id))
        resp = string(Kaimon.check_eval_tool.handler(Dict("eval_id" => eval_id)))
        @test occursin("running", resp)
        @test occursin("cancel requested", resp)
    end
end

@testset "terminal status: a pending request wins over completed/failed" begin
    eval_id = "cafe0004"
    mgr, rec = _cancel_test_fixture(eval_id)
    @test Kaimon._job_terminal_status(mgr, eval_id, false) == :completed
    @test Kaimon._job_terminal_status(mgr, eval_id, true) == :failed

    rec.cancel_requested_at = time()
    @test Kaimon._job_terminal_status(mgr, eval_id, false) == :cancelled
    @test Kaimon._job_terminal_status(mgr, eval_id, true) == :cancelled
end
