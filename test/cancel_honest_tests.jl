using ReTest
using Kaimon
using Kaimon.Database

# ── cancel_eval honesty ──────────────────────────────────────────────────────
# Regression: cancel_eval used to write status='cancelled' (with finished_at)
# at REQUEST time — before the eval had stopped. A job whose code never
# observed is_cancelled() stayed 'cancelled' in the DB forever while still
# burning CPU, so consumers (check_eval, waiters, the doctor) could not tell
# a dead job from a running one. The fix records an honest intermediate
# state — 'cancel_requested', no finished_at — and leaves the terminal
# status to the collector task that actually observes the eval's return.

@testset "cancel_eval honesty" begin
    Database.init_db!(tempname() * ".db")
    mgr = Kaimon.ConnectionManager(sock_dir = tempdir())
    eval_id = "cafe0001"
    Database.persist_job!(eval_id, "sess1234", "for i in 1:10^9; end", time(), time())
    rec = Kaimon.EvalRecord(eval_id, "sess1234", "for i in 1:10^9; end",
                            time(), 0.0, time(), :promoted, "", "", true,
                            Dict{String, String}())
    push!(mgr.eval_history, rec)

    old = Kaimon.GATE_CONN_MGR[]
    Kaimon.GATE_CONN_MGR[] = mgr
    try
        # No REPLConnection exists for the session, so the :cancel_job notify
        # is skipped — what we are testing is the record + DB transition.
        resp = Kaimon.cancel_eval_tool.handler(Dict("eval_id" => eval_id))

        @test rec.status == :cancel_requested      # was :cancelled
        @test rec.finished_at == 0.0               # the job has NOT finished
        @test occursin("cancel requested", string(resp))

        job = Database.get_job(eval_id)
        @test job !== nothing
        @test job["status"] == "cancel_requested"  # was "cancelled"
        @test job["finished_at"] == 0.0            # not stamped at request time
    finally
        Kaimon.GATE_CONN_MGR[] = old
    end
end
