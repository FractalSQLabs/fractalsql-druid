-- demo/demo-vertical-sovereign-edge-ai.sql
--
-- FractalSQL for Apache Druid -- industry vertical: sovereign, edge and
-- autonomous systems AI. Fifty edge-compute nodes, each with a
-- five-dimensional resource-capability vector; the facility layout's
-- spatial density; the sniper search that finds the node a GPU-heavy
-- inference workload belongs on; a diverse sample of the fleet's
-- distinct capability profiles; and the cardinality-constrained
-- optimizer repurposed as a general on-device black-box resource
-- allocator.
--
--   1. Fifty edge-compute nodes and their capability vectors.
--   2. fractal_dimension_boxcount: the facility deployment-grid density.
--   3. The sniper search: the ideal node profile for a GPU-inference
--      workload, and the real node it maps to.
--   4. fractal_search_explore: a diverse sample of the fleet's profiles.
--   5. fractal_optimize_portfolio: which 6 of the 50 nodes a
--      distributed job should land on.
--   6. A closing fractal_reason() narrates the placement decision.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- closing fractal_reason() narrative needs a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-sovereign-edge-ai.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The nodes, the facility grid and the throughput table are
--     fixture directives: Druid has no DDL, no VALUES and no recursive
--     CTE, and random values are the deterministic sin-hash the other kits use.
--   * The deployment grid's flat point cloud is an MSQ write with
--     ARRAY_AGG: Druid has no group_concat, and the cloud is the 800
--     flat coordinates of the grid.
--   * The sniper search is a SQL function plus a service call: the
--     refined profile comes out of the search as JSON, and the mapping
--     of that profile onto a real node is a corpus search over the
--     nodes' vectors -- a search over a whole column, which a Druid
--     aggregate cannot do.
--   * The optimizer's two flat vectors are assembled with ARRAY_AGG: the
--     throughput vector in node order, and the contention matrix in
--     row-major (node, node) order.
--   * The optimizer takes three arguments here; it is deterministic, so
--     there is no seed.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=<name> ok); the build_test kit gate greps for it.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Fifty edge-compute nodes and their capability vectors.
--
-- Each vector is [cpu_free, mem_free, gpu_avail, net_headroom,
-- battery], each component roughly normalized to [-1, 1] (1 = plenty of
-- headroom).
-- ---------------------------------------------------------------------------
-- @fixture vse_nodes {"rows": [
--   {"id": 1, "node_name": "edge-node-1", "capability": "0.4468,-0.4286,-0.1639,-0.5988,0.1518"},
--   {"id": 2, "node_name": "edge-node-2", "capability": "-0.4286,-0.1639,-0.5988,0.1518,0.9630"},
--   {"id": 3, "node_name": "edge-node-3", "capability": "-0.1639,-0.5988,0.1518,0.9630,0.8411"},
--   {"id": 4, "node_name": "edge-node-4", "capability": "-0.5988,0.1518,0.9630,0.8411,-0.0594"},
--   {"id": 5, "node_name": "edge-node-5", "capability": "0.1518,0.9630,0.8411,-0.0594,0.5364"},
--   {"id": 6, "node_name": "edge-node-6", "capability": "0.9630,0.8411,-0.0594,0.5364,0.1933"},
--   {"id": 7, "node_name": "edge-node-7", "capability": "0.8411,-0.0594,0.5364,0.1933,0.8685"},
--   {"id": 8, "node_name": "edge-node-8", "capability": "-0.0594,0.5364,0.1933,0.8685,-0.0938"},
--   {"id": 9, "node_name": "edge-node-9", "capability": "0.5364,0.1933,0.8685,-0.0938,-0.5691"},
--   {"id": 10, "node_name": "edge-node-10", "capability": "0.1933,0.8685,-0.0938,-0.5691,0.3894"},
--   {"id": 11, "node_name": "edge-node-11", "capability": "0.8685,-0.0938,-0.5691,0.3894,0.5919"},
--   {"id": 12, "node_name": "edge-node-12", "capability": "-0.0938,-0.5691,0.3894,0.5919,-0.4336"},
--   {"id": 13, "node_name": "edge-node-13", "capability": "-0.5691,0.3894,0.5919,-0.4336,0.0278"},
--   {"id": 14, "node_name": "edge-node-14", "capability": "0.3894,0.5919,-0.4336,0.0278,-0.7149"},
--   {"id": 15, "node_name": "edge-node-15", "capability": "0.5919,-0.4336,0.0278,-0.7149,-0.7712"},
--   {"id": 16, "node_name": "edge-node-16", "capability": "-0.4336,0.0278,-0.7149,-0.7712,-0.3956"},
--   {"id": 17, "node_name": "edge-node-17", "capability": "0.0278,-0.7149,-0.7712,-0.3956,-0.7682"},
--   {"id": 18, "node_name": "edge-node-18", "capability": "-0.7149,-0.7712,-0.3956,-0.7682,0.6240"},
--   {"id": 19, "node_name": "edge-node-19", "capability": "-0.7712,-0.3956,-0.7682,0.6240,0.1078"},
--   {"id": 20, "node_name": "edge-node-20", "capability": "-0.3956,-0.7682,0.6240,0.1078,-0.1907"},
--   {"id": 21, "node_name": "edge-node-21", "capability": "-0.7682,0.6240,0.1078,-0.1907,0.7458"},
--   {"id": 22, "node_name": "edge-node-22", "capability": "0.6240,0.1078,-0.1907,0.7458,-0.0507"},
--   {"id": 23, "node_name": "edge-node-23", "capability": "0.1078,-0.1907,0.7458,-0.0507,-0.5500"},
--   {"id": 24, "node_name": "edge-node-24", "capability": "-0.1907,0.7458,-0.0507,-0.5500,-0.3813"},
--   {"id": 25, "node_name": "edge-node-25", "capability": "0.7458,-0.0507,-0.5500,-0.3813,-0.6502"},
--   {"id": 26, "node_name": "edge-node-26", "capability": "-0.0507,-0.5500,-0.3813,-0.6502,-0.6604"},
--   {"id": 27, "node_name": "edge-node-27", "capability": "-0.5500,-0.3813,-0.6502,-0.6604,-0.8356"},
--   {"id": 28, "node_name": "edge-node-28", "capability": "-0.3813,-0.6502,-0.6604,-0.8356,0.6218"},
--   {"id": 29, "node_name": "edge-node-29", "capability": "-0.6502,-0.6604,-0.8356,0.6218,-0.9667"},
--   {"id": 30, "node_name": "edge-node-30", "capability": "-0.6604,-0.8356,0.6218,-0.9667,-0.8239"},
--   {"id": 31, "node_name": "edge-node-31", "capability": "-0.8356,0.6218,-0.9667,-0.8239,-0.8449"},
--   {"id": 32, "node_name": "edge-node-32", "capability": "0.6218,-0.9667,-0.8239,-0.8449,0.1952"},
--   {"id": 33, "node_name": "edge-node-33", "capability": "-0.9667,-0.8239,-0.8449,0.1952,-0.5170"},
--   {"id": 34, "node_name": "edge-node-34", "capability": "-0.8239,-0.8449,0.1952,-0.5170,-0.2239"},
--   {"id": 35, "node_name": "edge-node-35", "capability": "-0.8449,0.1952,-0.5170,-0.2239,-0.3436"},
--   {"id": 36, "node_name": "edge-node-36", "capability": "0.1952,-0.5170,-0.2239,-0.3436,-0.2643"},
--   {"id": 37, "node_name": "edge-node-37", "capability": "-0.5170,-0.2239,-0.3436,-0.2643,0.0147"},
--   {"id": 38, "node_name": "edge-node-38", "capability": "-0.2239,-0.3436,-0.2643,0.0147,-0.6535"},
--   {"id": 39, "node_name": "edge-node-39", "capability": "-0.3436,-0.2643,0.0147,-0.6535,-0.9422"},
--   {"id": 40, "node_name": "edge-node-40", "capability": "-0.2643,0.0147,-0.6535,-0.9422,-0.6195"},
--   {"id": 41, "node_name": "edge-node-41", "capability": "0.0147,-0.6535,-0.9422,-0.6195,0.1898"},
--   {"id": 42, "node_name": "edge-node-42", "capability": "-0.6535,-0.9422,-0.6195,0.1898,-0.6918"},
--   {"id": 43, "node_name": "edge-node-43", "capability": "-0.9422,-0.6195,0.1898,-0.6918,0.3855"},
--   {"id": 44, "node_name": "edge-node-44", "capability": "-0.6195,0.1898,-0.6918,0.3855,-0.6317"},
--   {"id": 45, "node_name": "edge-node-45", "capability": "0.1898,-0.6918,0.3855,-0.6317,-0.9116"},
--   {"id": 46, "node_name": "edge-node-46", "capability": "-0.6918,0.3855,-0.6317,-0.9116,0.4678"},
--   {"id": 47, "node_name": "edge-node-47", "capability": "0.3855,-0.6317,-0.9116,0.4678,-0.1371"},
--   {"id": 48, "node_name": "edge-node-48", "capability": "-0.6317,-0.9116,0.4678,-0.1371,-0.8209"},
--   {"id": 49, "node_name": "edge-node-49", "capability": "-0.9116,0.4678,-0.1371,-0.8209,-0.4452"},
--   {"id": 50, "node_name": "edge-node-50", "capability": "0.4678,-0.1371,-0.8209,-0.4452,-0.8119"}
-- ]};

SELECT (SELECT COUNT(*) FROM "vse_nodes") AS "nodes";

-- ---------------------------------------------------------------------------
-- 2. The facility deployment grid's spatial density.
--
-- A 20x20 grid of candidate rack positions with small placement
-- jitter -- a spatial-complexity signal for constrained-compute
-- monitoring, the spatial sibling of DFA's own time-series complexity
-- signal. A dimension near 2.0 means the deployment fills the
-- available floor space; a lower number would flag a sparse or
-- corner-clustered rollout.
-- ---------------------------------------------------------------------------
-- @fixture vse_grid {"rows": [
--   {"id": 1, "pos": "-0.0379,-0.0140"},
--   {"id": 2, "pos": "-0.0140,1.0378"},
--   {"id": 3, "pos": "0.0378,1.8997"},
--   {"id": 4, "pos": "-0.1003,2.9487"},
--   {"id": 5, "pos": "-0.0513,4.0119"},
--   {"id": 6, "pos": "0.0119,5.1415"},
--   {"id": 7, "pos": "0.1415,6.0964"},
--   {"id": 8, "pos": "0.0964,6.9037"},
--   {"id": 9, "pos": "-0.0963,8.1486"},
--   {"id": 10, "pos": "0.1486,9.0948"},
--   {"id": 11, "pos": "0.0948,9.9825"},
--   {"id": 12, "pos": "-0.0175,11.1281"},
--   {"id": 13, "pos": "0.1281,11.9803"},
--   {"id": 14, "pos": "-0.0197,13.0433"},
--   {"id": 15, "pos": "0.0433,13.9468"},
--   {"id": 16, "pos": "-0.0532,15.0781"},
--   {"id": 17, "pos": "0.0781,16.0168"},
--   {"id": 18, "pos": "0.0168,17.0483"},
--   {"id": 19, "pos": "0.0483,17.9758"},
--   {"id": 20, "pos": "-0.0242,18.8907"},
--   {"id": 21, "pos": "0.8907,-0.0509"},
--   {"id": 22, "pos": "0.9491,0.9986"},
--   {"id": 23, "pos": "0.9986,1.8501"},
--   {"id": 24, "pos": "0.8501,2.8986"},
--   {"id": 25, "pos": "0.8986,3.9761"},
--   {"id": 26, "pos": "0.9761,5.1455"},
--   {"id": 27, "pos": "1.1455,6.0670"},
--   {"id": 28, "pos": "1.0670,6.9357"},
--   {"id": 29, "pos": "0.9357,7.9754"},
--   {"id": 30, "pos": "0.9754,8.9102"},
--   {"id": 31, "pos": "0.9102,10.0228"},
--   {"id": 32, "pos": "1.0228,11.1445"},
--   {"id": 33, "pos": "1.1445,12.1262"},
--   {"id": 34, "pos": "1.1262,12.9911"},
--   {"id": 35, "pos": "0.9911,14.0805"},
--   {"id": 36, "pos": "1.0805,15.0290"},
--   {"id": 37, "pos": "1.0290,16.1303"},
--   {"id": 38, "pos": "1.1303,16.9859"},
--   {"id": 39, "pos": "0.9859,17.9146"},
--   {"id": 40, "pos": "0.9146,19.0584"},
--   {"id": 41, "pos": "2.0584,0.0888"},
--   {"id": 42, "pos": "2.0888,0.9350"},
--   {"id": 43, "pos": "1.9350,2.0042"},
--   {"id": 44, "pos": "2.0042,2.8928"},
--   {"id": 45, "pos": "1.8928,3.8843"},
--   {"id": 46, "pos": "1.8843,4.9407"},
--   {"id": 47, "pos": "1.9407,5.8848"},
--   {"id": 48, "pos": "1.8848,7.0936"},
--   {"id": 49, "pos": "2.0936,8.0162"},
--   {"id": 50, "pos": "2.0162,8.9714"},
--   {"id": 51, "pos": "1.9714,10.1119"},
--   {"id": 52, "pos": "2.1119,10.9924"},
--   {"id": 53, "pos": "1.9924,11.9175"},
--   {"id": 54, "pos": "1.9175,12.9428"},
--   {"id": 55, "pos": "1.9428,13.9025"},
--   {"id": 56, "pos": "1.9025,14.9009"},
--   {"id": 57, "pos": "1.9009,15.8747"},
--   {"id": 58, "pos": "1.8747,17.0933"},
--   {"id": 59, "pos": "2.0933,17.8550"},
--   {"id": 60, "pos": "1.8550,18.8764"},
--   {"id": 61, "pos": "2.8764,-0.1267"},
--   {"id": 62, "pos": "2.8733,1.0293"},
--   {"id": 63, "pos": "3.0293,1.9224"},
--   {"id": 64, "pos": "2.9224,2.9664"},
--   {"id": 65, "pos": "2.9664,3.9485"},
--   {"id": 66, "pos": "2.9485,4.9604"},
--   {"id": 67, "pos": "2.9604,6.0022"},
--   {"id": 68, "pos": "3.0022,6.9020"},
--   {"id": 69, "pos": "2.9020,7.8587"},
--   {"id": 70, "pos": "2.8587,8.9071"},
--   {"id": 71, "pos": "2.9071,10.0285"},
--   {"id": 72, "pos": "3.0285,10.8962"},
--   {"id": 73, "pos": "2.8962,12.0578"},
--   {"id": 74, "pos": "3.0578,12.9052"},
--   {"id": 75, "pos": "2.9052,13.8633"},
--   {"id": 76, "pos": "2.8633,15.0702"},
--   {"id": 77, "pos": "3.0702,15.9794"},
--   {"id": 78, "pos": "2.9794,16.8769"},
--   {"id": 79, "pos": "2.8769,17.9332"},
--   {"id": 80, "pos": "2.9332,18.8782"},
--   {"id": 81, "pos": "3.8782,-0.0371"},
--   {"id": 82, "pos": "3.9629,0.9954"},
--   {"id": 83, "pos": "3.9954,1.9574"},
--   {"id": 84, "pos": "3.9574,2.9832"},
--   {"id": 85, "pos": "3.9832,4.1284"},
--   {"id": 86, "pos": "4.1284,5.0946"},
--   {"id": 87, "pos": "4.0946,5.8924"},
--   {"id": 88, "pos": "3.8924,7.0089"},
--   {"id": 89, "pos": "4.0089,8.0712"},
--   {"id": 90, "pos": "4.0712,9.0843"},
--   {"id": 91, "pos": "4.0843,10.0753"},
--   {"id": 92, "pos": "4.0753,11.1284"},
--   {"id": 93, "pos": "4.1284,11.8939"},
--   {"id": 94, "pos": "3.8939,12.8667"},
--   {"id": 95, "pos": "3.8667,13.9970"},
--   {"id": 96, "pos": "3.9970,14.9292"},
--   {"id": 97, "pos": "3.9292,16.1299"},
--   {"id": 98, "pos": "4.1299,16.8737"},
--   {"id": 99, "pos": "3.8737,17.8997"},
--   {"id": 100, "pos": "3.8997,18.9993"},
--   {"id": 101, "pos": "4.9993,0.1180"},
--   {"id": 102, "pos": "5.1180,0.9531"},
--   {"id": 103, "pos": "4.9531,2.0217"},
--   {"id": 104, "pos": "5.0217,3.0651"},
--   {"id": 105, "pos": "5.0651,4.1335"},
--   {"id": 106, "pos": "5.1335,4.9124"},
--   {"id": 107, "pos": "4.9124,6.0424"},
--   {"id": 108, "pos": "5.0424,6.8641"},
--   {"id": 109, "pos": "4.8641,7.8594"},
--   {"id": 110, "pos": "4.8594,8.9998"},
--   {"id": 111, "pos": "4.9998,9.9870"},
--   {"id": 112, "pos": "4.9870,10.9903"},
--   {"id": 113, "pos": "4.9903,12.1249"},
--   {"id": 114, "pos": "5.1249,12.9705"},
--   {"id": 115, "pos": "4.9705,14.1485"},
--   {"id": 116, "pos": "5.1485,14.9304"},
--   {"id": 117, "pos": "4.9304,16.0788"},
--   {"id": 118, "pos": "5.0788,17.1422"},
--   {"id": 119, "pos": "5.1422,17.8820"},
--   {"id": 120, "pos": "4.8820,18.8503"},
--   {"id": 121, "pos": "5.8503,0.0694"},
--   {"id": 122, "pos": "6.0694,0.9418"},
--   {"id": 123, "pos": "5.9418,1.9128"},
--   {"id": 124, "pos": "5.9128,3.1303"},
--   {"id": 125, "pos": "6.1303,3.9309"},
--   {"id": 126, "pos": "5.9309,4.9799"},
--   {"id": 127, "pos": "5.9799,6.0943"},
--   {"id": 128, "pos": "6.0943,7.0824"},
--   {"id": 129, "pos": "6.0824,7.8555"},
--   {"id": 130, "pos": "5.8555,9.0205"},
--   {"id": 131, "pos": "6.0205,10.0947"},
--   {"id": 132, "pos": "6.0947,10.8932"},
--   {"id": 133, "pos": "5.8932,12.0923"},
--   {"id": 134, "pos": "6.0923,13.0975"},
--   {"id": 135, "pos": "6.0975,13.9088"},
--   {"id": 136, "pos": "5.9088,14.9822"},
--   {"id": 137, "pos": "5.9822,16.0823"},
--   {"id": 138, "pos": "6.0823,17.0808"},
--   {"id": 139, "pos": "6.0808,18.1098"},
--   {"id": 140, "pos": "6.1098,18.8749"},
--   {"id": 141, "pos": "6.8749,0.0668"},
--   {"id": 142, "pos": "7.0668,1.1001"},
--   {"id": 143, "pos": "7.1001,2.1288"},
--   {"id": 144, "pos": "7.1288,3.0303"},
--   {"id": 145, "pos": "7.0303,3.9944"},
--   {"id": 146, "pos": "6.9944,5.1216"},
--   {"id": 147, "pos": "7.1216,5.8550"},
--   {"id": 148, "pos": "6.8550,6.8745"},
--   {"id": 149, "pos": "6.8745,8.0630"},
--   {"id": 150, "pos": "7.0630,9.0066"},
--   {"id": 151, "pos": "7.0066,10.1177"},
--   {"id": 152, "pos": "7.1177,11.1347"},
--   {"id": 153, "pos": "7.1347,12.0068"},
--   {"id": 154, "pos": "7.0068,12.9257"},
--   {"id": 155, "pos": "6.9257,13.9494"},
--   {"id": 156, "pos": "6.9494,15.1225"},
--   {"id": 157, "pos": "7.1225,16.0149"},
--   {"id": 158, "pos": "7.0149,16.8732"},
--   {"id": 159, "pos": "6.8732,18.0047"},
--   {"id": 160, "pos": "7.0047,18.9033"},
--   {"id": 161, "pos": "7.9033,-0.0141"},
--   {"id": 162, "pos": "7.9859,1.0677"},
--   {"id": 163, "pos": "8.0677,2.0739"},
--   {"id": 164, "pos": "8.0739,3.0012"},
--   {"id": 165, "pos": "8.0012,4.0519"},
--   {"id": 166, "pos": "8.0519,4.8565"},
--   {"id": 167, "pos": "7.8565,6.0665"},
--   {"id": 168, "pos": "8.0665,7.1086"},
--   {"id": 169, "pos": "8.1086,8.0900"},
--   {"id": 170, "pos": "8.0900,8.9993"},
--   {"id": 171, "pos": "7.9993,10.0400"},
--   {"id": 172, "pos": "8.0400,10.9044"},
--   {"id": 173, "pos": "7.9044,11.9666"},
--   {"id": 174, "pos": "7.9666,13.1420"},
--   {"id": 175, "pos": "8.1420,13.9533"},
--   {"id": 176, "pos": "7.9533,15.1419"},
--   {"id": 177, "pos": "8.1419,15.9896"},
--   {"id": 178, "pos": "7.9896,17.0603"},
--   {"id": 179, "pos": "8.0603,18.0984"},
--   {"id": 180, "pos": "8.0984,18.8504"},
--   {"id": 181, "pos": "8.8504,-0.1254"},
--   {"id": 182, "pos": "8.8746,1.1218"},
--   {"id": 183, "pos": "9.1218,2.0666"},
--   {"id": 184, "pos": "9.0666,2.9869"},
--   {"id": 185, "pos": "8.9869,3.8912"},
--   {"id": 186, "pos": "8.8912,5.0332"},
--   {"id": 187, "pos": "9.0332,5.9041"},
--   {"id": 188, "pos": "8.9041,7.0190"},
--   {"id": 189, "pos": "9.0190,7.8783"},
--   {"id": 190, "pos": "8.8783,9.1422"},
--   {"id": 191, "pos": "9.1422,10.0383"},
--   {"id": 192, "pos": "9.0383,10.9415"},
--   {"id": 193, "pos": "8.9415,12.0880"},
--   {"id": 194, "pos": "9.0880,12.8977"},
--   {"id": 195, "pos": "8.8977,13.9903"},
--   {"id": 196, "pos": "8.9903,15.0249"},
--   {"id": 197, "pos": "9.0249,15.9021"},
--   {"id": 198, "pos": "8.9021,17.0067"},
--   {"id": 199, "pos": "9.0067,17.9614"},
--   {"id": 200, "pos": "8.9614,19.1105"},
--   {"id": 201, "pos": "10.1105,0.0420"},
--   {"id": 202, "pos": "10.0420,0.9309"},
--   {"id": 203, "pos": "9.9309,2.1160"},
--   {"id": 204, "pos": "10.1160,3.1415"},
--   {"id": 205, "pos": "10.1415,3.9773"},
--   {"id": 206, "pos": "9.9773,4.9315"},
--   {"id": 207, "pos": "9.9315,5.9139"},
--   {"id": 208, "pos": "9.9139,7.0948"},
--   {"id": 209, "pos": "10.0948,8.0892"},
--   {"id": 210, "pos": "10.0892,9.0273"},
--   {"id": 211, "pos": "10.0273,9.9182"},
--   {"id": 212, "pos": "9.9182,11.1475"},
--   {"id": 213, "pos": "10.1475,11.8843"},
--   {"id": 214, "pos": "9.8843,13.1094"},
--   {"id": 215, "pos": "10.1094,13.9587"},
--   {"id": 216, "pos": "9.9587,15.0378"},
--   {"id": 217, "pos": "10.0378,15.9964"},
--   {"id": 218, "pos": "9.9964,16.9369"},
--   {"id": 219, "pos": "9.9369,18.0713"},
--   {"id": 220, "pos": "10.0713,18.9933"},
--   {"id": 221, "pos": "10.9933,-0.0010"},
--   {"id": 222, "pos": "10.9990,0.8721"},
--   {"id": 223, "pos": "10.8721,1.9993"},
--   {"id": 224, "pos": "10.9993,3.1002"},
--   {"id": 225, "pos": "11.1002,3.9688"},
--   {"id": 226, "pos": "10.9688,5.1046"},
--   {"id": 227, "pos": "11.1046,6.0178"},
--   {"id": 228, "pos": "11.0178,7.0696"},
--   {"id": 229, "pos": "11.0696,7.9691"},
--   {"id": 230, "pos": "10.9691,8.9527"},
--   {"id": 231, "pos": "10.9527,10.0311"},
--   {"id": 232, "pos": "11.0311,10.9204"},
--   {"id": 233, "pos": "10.9204,11.9728"},
--   {"id": 234, "pos": "10.9728,13.0382"},
--   {"id": 235, "pos": "11.0382,13.9696"},
--   {"id": 236, "pos": "10.9696,15.0505"},
--   {"id": 237, "pos": "11.0505,16.0611"},
--   {"id": 238, "pos": "11.0611,16.9974"},
--   {"id": 239, "pos": "10.9974,17.8837"},
--   {"id": 240, "pos": "10.8837,18.9562"},
--   {"id": 241, "pos": "11.9562,-0.0465"},
--   {"id": 242, "pos": "11.9535,1.0735"},
--   {"id": 243, "pos": "12.0735,2.1326"},
--   {"id": 244, "pos": "12.1326,3.0131"},
--   {"id": 245, "pos": "12.0131,4.0251"},
--   {"id": 246, "pos": "12.0251,5.0793"},
--   {"id": 247, "pos": "12.0793,5.9461"},
--   {"id": 248, "pos": "11.9461,7.0455"},
--   {"id": 249, "pos": "12.0455,7.8629"},
--   {"id": 250, "pos": "11.8629,9.1461"},
--   {"id": 251, "pos": "12.1461,10.1391"},
--   {"id": 252, "pos": "12.1391,11.1084"},
--   {"id": 253, "pos": "12.1084,11.9567"},
--   {"id": 254, "pos": "11.9567,12.9063"},
--   {"id": 255, "pos": "11.9063,13.9486"},
--   {"id": 256, "pos": "11.9486,15.0345"},
--   {"id": 257, "pos": "12.0345,15.8588"},
--   {"id": 258, "pos": "11.8588,17.0304"},
--   {"id": 259, "pos": "12.0304,18.1420"},
--   {"id": 260, "pos": "12.1420,19.1259"},
--   {"id": 261, "pos": "13.1259,-0.0034"},
--   {"id": 262, "pos": "12.9966,0.8555"},
--   {"id": 263, "pos": "12.8555,1.9261"},
--   {"id": 264, "pos": "12.9261,3.0350"},
--   {"id": 265, "pos": "13.0350,4.0396"},
--   {"id": 266, "pos": "13.0396,4.9705"},
--   {"id": 267, "pos": "12.9705,5.9258"},
--   {"id": 268, "pos": "12.9258,7.0107"},
--   {"id": 269, "pos": "13.0107,7.9344"},
--   {"id": 270, "pos": "12.9344,9.0039"},
--   {"id": 271, "pos": "13.0039,9.9980"},
--   {"id": 272, "pos": "12.9980,10.9834"},
--   {"id": 273, "pos": "12.9834,12.0943"},
--   {"id": 274, "pos": "13.0943,12.9797"},
--   {"id": 275, "pos": "12.9797,13.9256"},
--   {"id": 276, "pos": "12.9256,14.9642"},
--   {"id": 277, "pos": "12.9642,15.8857"},
--   {"id": 278, "pos": "12.8857,16.9547"},
--   {"id": 279, "pos": "12.9547,17.9322"},
--   {"id": 280, "pos": "12.9322,18.9578"},
--   {"id": 281, "pos": "13.9578,0.1115"},
--   {"id": 282, "pos": "14.1115,1.0096"},
--   {"id": 283, "pos": "14.0096,1.9509"},
--   {"id": 284, "pos": "13.9509,2.9203"},
--   {"id": 285, "pos": "13.9203,3.9608"},
--   {"id": 286, "pos": "13.9608,5.0560"},
--   {"id": 287, "pos": "14.0560,6.0058"},
--   {"id": 288, "pos": "14.0058,7.1191"},
--   {"id": 289, "pos": "14.1191,8.0688"},
--   {"id": 290, "pos": "14.0688,9.0194"},
--   {"id": 291, "pos": "14.0194,9.9428"},
--   {"id": 292, "pos": "13.9428,11.1463"},
--   {"id": 293, "pos": "14.1463,11.8594"},
--   {"id": 294, "pos": "13.8594,12.9379"},
--   {"id": 295, "pos": "13.9379,14.1140"},
--   {"id": 296, "pos": "14.1140,14.8970"},
--   {"id": 297, "pos": "13.8970,15.9402"},
--   {"id": 298, "pos": "13.9402,17.1177"},
--   {"id": 299, "pos": "14.1177,17.9870"},
--   {"id": 300, "pos": "13.9870,19.0202"},
--   {"id": 301, "pos": "15.0202,0.0624"},
--   {"id": 302, "pos": "15.0624,0.9176"},
--   {"id": 303, "pos": "14.9176,1.9520"},
--   {"id": 304, "pos": "14.9520,3.0689"},
--   {"id": 305, "pos": "15.0689,4.1329"},
--   {"id": 306, "pos": "15.1329,4.9844"},
--   {"id": 307, "pos": "14.9844,6.0368"},
--   {"id": 308, "pos": "15.0368,6.9758"},
--   {"id": 309, "pos": "14.9758,7.9596"},
--   {"id": 310, "pos": "14.9596,9.0395"},
--   {"id": 311, "pos": "15.0395,10.1361"},
--   {"id": 312, "pos": "15.1361,10.8793"},
--   {"id": 313, "pos": "14.8793,11.8912"},
--   {"id": 314, "pos": "14.8912,13.1123"},
--   {"id": 315, "pos": "15.1123,14.1254"},
--   {"id": 316, "pos": "15.1254,15.0949"},
--   {"id": 317, "pos": "15.0949,16.1276"},
--   {"id": 318, "pos": "15.1276,17.0843"},
--   {"id": 319, "pos": "15.0843,17.9548"},
--   {"id": 320, "pos": "14.9548,19.0289"},
--   {"id": 321, "pos": "16.0289,-0.0531"},
--   {"id": 322, "pos": "15.9469,1.0647"},
--   {"id": 323, "pos": "16.0647,2.0667"},
--   {"id": 324, "pos": "16.0667,3.0459"},
--   {"id": 325, "pos": "16.0459,4.0960"},
--   {"id": 326, "pos": "16.0960,5.1165"},
--   {"id": 327, "pos": "16.1165,5.9665"},
--   {"id": 328, "pos": "15.9665,7.0794"},
--   {"id": 329, "pos": "16.0794,8.1117"},
--   {"id": 330, "pos": "16.1117,8.9436"},
--   {"id": 331, "pos": "15.9436,10.1358"},
--   {"id": 332, "pos": "16.1358,10.9479"},
--   {"id": 333, "pos": "15.9479,12.1433"},
--   {"id": 334, "pos": "16.1433,13.0169"},
--   {"id": 335, "pos": "16.0169,14.1158"},
--   {"id": 336, "pos": "16.1158,15.1081"},
--   {"id": 337, "pos": "16.1081,16.0644"},
--   {"id": 338, "pos": "16.0644,16.9408"},
--   {"id": 339, "pos": "15.9408,18.1027"},
--   {"id": 340, "pos": "16.1027,18.9861"},
--   {"id": 341, "pos": "16.9861,0.0080"},
--   {"id": 342, "pos": "17.0080,1.0148"},
--   {"id": 343, "pos": "17.0148,1.9063"},
--   {"id": 344, "pos": "16.9063,2.9217"},
--   {"id": 345, "pos": "16.9217,4.0459"},
--   {"id": 346, "pos": "17.0459,5.0542"},
--   {"id": 347, "pos": "17.0542,5.9800"},
--   {"id": 348, "pos": "16.9800,7.0856"},
--   {"id": 349, "pos": "17.0856,7.9625"},
--   {"id": 350, "pos": "16.9625,8.9564"},
--   {"id": 351, "pos": "16.9564,9.9814"},
--   {"id": 352, "pos": "16.9814,11.1159"},
--   {"id": 353, "pos": "17.1159,12.0723"},
--   {"id": 354, "pos": "17.0723,12.9095"},
--   {"id": 355, "pos": "16.9095,13.9634"},
--   {"id": 356, "pos": "16.9634,14.9645"},
--   {"id": 357, "pos": "16.9645,16.1040"},
--   {"id": 358, "pos": "17.1040,16.9989"},
--   {"id": 359, "pos": "16.9989,17.8817"},
--   {"id": 360, "pos": "16.8817,19.0883"},
--   {"id": 361, "pos": "18.0883,-0.1113"},
--   {"id": 362, "pos": "17.8887,1.0021"},
--   {"id": 363, "pos": "18.0021,1.8914"},
--   {"id": 364, "pos": "17.8914,3.1187"},
--   {"id": 365, "pos": "18.1187,4.0784"},
--   {"id": 366, "pos": "18.0784,5.1322"},
--   {"id": 367, "pos": "18.1322,5.9638"},
--   {"id": 368, "pos": "17.9638,7.1195"},
--   {"id": 369, "pos": "18.1195,8.0341"},
--   {"id": 370, "pos": "18.0341,8.9409"},
--   {"id": 371, "pos": "17.9409,10.1245"},
--   {"id": 372, "pos": "18.1245,10.9738"},
--   {"id": 373, "pos": "17.9738,11.9729"},
--   {"id": 374, "pos": "17.9729,13.1154"},
--   {"id": 375, "pos": "18.1154,13.9919"},
--   {"id": 376, "pos": "17.9919,15.1300"},
--   {"id": 377, "pos": "18.1300,15.8578"},
--   {"id": 378, "pos": "17.8578,16.8612"},
--   {"id": 379, "pos": "17.8612,17.9363"},
--   {"id": 380, "pos": "17.9363,18.8864"},
--   {"id": 381, "pos": "18.8864,0.0947"},
--   {"id": 382, "pos": "19.0947,0.9372"},
--   {"id": 383, "pos": "18.9372,2.1427"},
--   {"id": 384, "pos": "19.1427,3.0467"},
--   {"id": 385, "pos": "19.0467,4.0985"},
--   {"id": 386, "pos": "19.0985,5.0104"},
--   {"id": 387, "pos": "19.0104,5.9147"},
--   {"id": 388, "pos": "18.9147,6.9176"},
--   {"id": 389, "pos": "18.9176,7.9125"},
--   {"id": 390, "pos": "18.9125,8.9243"},
--   {"id": 391, "pos": "18.9243,9.9048"},
--   {"id": 392, "pos": "18.9048,11.0457"},
--   {"id": 393, "pos": "19.0457,12.0122"},
--   {"id": 394, "pos": "19.0122,13.0954"},
--   {"id": 395, "pos": "19.0954,14.0739"},
--   {"id": 396, "pos": "19.0739,14.8892"},
--   {"id": 397, "pos": "18.8892,16.0687"},
--   {"id": 398, "pos": "19.0687,17.0229"},
--   {"id": 399, "pos": "19.0229,18.0333"},
--   {"id": 400, "pos": "19.0333,18.9889"}
-- ]};

REPLACE INTO vse_cloud OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("pos" AS VARCHAR), 65536), ',') AS "cloud"
FROM "vse_grid"
PARTITIONED BY ALL;

SELECT fractal_dimension_boxcount("cloud", 2) AS "deployment_grid_dimension"
FROM "vse_cloud";

-- ---------------------------------------------------------------------------
-- 3. The sniper search: the ideal node profile for a GPU-inference
--    workload.
--
-- The SFS refines the workload vector into an ideal profile, and the
-- telemetry search then maps that profile onto a REAL node.
-- ---------------------------------------------------------------------------
SELECT fractal_json_value("d", '$.best_fit') AS "best_fit",
       fractal_json_text("d", '$.best_point') AS "refined_profile"
FROM (SELECT fractal_search_debug('[0.3,0.6,0.9,0.2,0.0]', 50, 50, 2) AS "d")
GROUP BY "d";

-- The refined profile, as the core's text vector form.
REPLACE INTO vse_profile OVERWRITE ALL
SELECT fractal_json_text("d", '$.best_point') AS "profile"
FROM (SELECT fractal_search_debug('[0.3,0.6,0.9,0.2,0.0]', 50, 50, 2) AS "d")
GROUP BY "d"
PARTITIONED BY ALL;

-- The real node the refined profile maps to.
-- @call search/telemetry {"table": "vse_nodes", "column": "capability",
--                        "id_column": "id", "query_table": "vse_profile",
--                        "query_column": "profile", "k": 5} AS vse_assign;

SELECT r."doc_id" AS "node_id", n."node_name" AS "node_name",
       ROUND(r."distance", 6) AS "distance",
       ROUND(1.0 / (1.0 + r."distance"), 6) AS "confidence"
FROM "vse_assign" r, "vse_nodes" n
WHERE r."doc_id" = n."id"
GROUP BY r."doc_id", n."node_name", r."distance"
ORDER BY r."distance";

-- ---------------------------------------------------------------------------
-- 4. fractal_search_explore: a diverse sample of the fleet's distinct
--    capability profiles.
--
-- "What KINDS of nodes do we actually have", which is what a capacity
-- plan needs, without scanning all 50 by hand.
-- ---------------------------------------------------------------------------
-- @call search/explore {"datasource": "vse_nodes", "vectorColumn": "capability",
--                      "idColumn": "id", "query": "0,0,0,0,0", "k": 6,
--                      "params": "{\"population_size\": 6, \"iterations\": 8}"} AS vse_scout;

SELECT z."ord" AS "ord", n."id" AS "id", n."node_name" AS "node_name"
FROM "vse_scout" z, "vse_nodes" n
WHERE z."doc_id" = n."id"
GROUP BY z."ord", n."id", n."node_name"
ORDER BY z."ord";

-- The same profiles, scored against the first node's own capability
-- vector: the nearest result is itself, with a score of 1.
SELECT n."id" AS "id", n."node_name" AS "node_name",
       ROUND(1.0 - fractal_vector_cosine_distance(a."capability", n."capability"), 4) AS "score"
FROM "vse_scout" z, "vse_nodes" n, "vse_nodes" a
WHERE z."doc_id" = n."id" AND a."id" = 1
GROUP BY n."id", n."node_name", a."capability", n."capability"
ORDER BY "score" DESC;

-- ---------------------------------------------------------------------------
-- 5. fractal_optimize_portfolio as a general on-device black-box
--    resource allocator.
--
-- Which 6 of the 50 nodes should a distributed job land on,
-- maximizing an "efficiency Sharpe" over expected throughput (mu)
-- against contention risk (cov: higher between nodes on the same
-- rack). Cardinality-constrained, NP-hard in general -- exactly the
-- ruggedness class this SFS-backed optimizer targets.
-- ---------------------------------------------------------------------------
-- @fixture vse_throughput {"rows": [
--   {"node_id": 1, "mu": 0.775652, "rack": 0},
--   {"node_id": 2, "mu": 0.499348, "rack": 0},
--   {"node_id": 3, "mu": 0.597467, "rack": 0},
--   {"node_id": 4, "mu": 0.723775, "rack": 0},
--   {"node_id": 5, "mu": 0.982907, "rack": 0},
--   {"node_id": 6, "mu": 0.892714, "rack": 0},
--   {"node_id": 7, "mu": 0.507426, "rack": 0},
--   {"node_id": 8, "mu": 0.997103, "rack": 0},
--   {"node_id": 9, "mu": 0.889615, "rack": 0},
--   {"node_id": 10, "mu": 0.66509, "rack": 0},
--   {"node_id": 11, "mu": 0.956127, "rack": 1},
--   {"node_id": 12, "mu": 0.660517, "rack": 1},
--   {"node_id": 13, "mu": 0.786512, "rack": 1},
--   {"node_id": 14, "mu": 0.593586, "rack": 1},
--   {"node_id": 15, "mu": 0.856226, "rack": 1},
--   {"node_id": 16, "mu": 0.733618, "rack": 1},
--   {"node_id": 17, "mu": 0.796526, "rack": 1},
--   {"node_id": 18, "mu": 0.651603, "rack": 1},
--   {"node_id": 19, "mu": 0.481458, "rack": 1},
--   {"node_id": 20, "mu": 0.598282, "rack": 1},
--   {"node_id": 21, "mu": 0.697194, "rack": 2},
--   {"node_id": 22, "mu": 0.400191, "rack": 2},
--   {"node_id": 23, "mu": 0.497143, "rack": 2},
--   {"node_id": 24, "mu": 0.652116, "rack": 2},
--   {"node_id": 25, "mu": 0.991049, "rack": 2},
--   {"node_id": 26, "mu": 0.834045, "rack": 2},
--   {"node_id": 27, "mu": 0.571421, "rack": 2},
--   {"node_id": 28, "mu": 0.650826, "rack": 2},
--   {"node_id": 29, "mu": 0.520359, "rack": 2},
--   {"node_id": 30, "mu": 0.745552, "rack": 2},
--   {"node_id": 31, "mu": 0.988912, "rack": 3},
--   {"node_id": 32, "mu": 0.952341, "rack": 3},
--   {"node_id": 33, "mu": 0.682166, "rack": 3},
--   {"node_id": 34, "mu": 0.860923, "rack": 3},
--   {"node_id": 35, "mu": 0.757992, "rack": 3},
--   {"node_id": 36, "mu": 0.960558, "rack": 3},
--   {"node_id": 37, "mu": 0.671849, "rack": 3},
--   {"node_id": 38, "mu": 0.529259, "rack": 3},
--   {"node_id": 39, "mu": 0.816829, "rack": 3},
--   {"node_id": 40, "mu": 0.877583, "rack": 3},
--   {"node_id": 41, "mu": 0.569914, "rack": 4},
--   {"node_id": 42, "mu": 0.708341, "rack": 4},
--   {"node_id": 43, "mu": 0.485518, "rack": 4},
--   {"node_id": 44, "mu": 0.468631, "rack": 4},
--   {"node_id": 45, "mu": 0.58132, "rack": 4},
--   {"node_id": 46, "mu": 0.469535, "rack": 4},
--   {"node_id": 47, "mu": 0.887199, "rack": 4},
--   {"node_id": 48, "mu": 0.732336, "rack": 4},
--   {"node_id": 49, "mu": 0.642786, "rack": 4},
--   {"node_id": 50, "mu": 0.92374, "rack": 4}
-- ]};

-- The contention matrix, in row-major (node, node) order.
REPLACE INTO vse_contention OVERWRITE ALL
SELECT a."node_id" AS "i", b."node_id" AS "j",
       CASE WHEN a."node_id" = b."node_id" THEN 0.05
            WHEN a."rack" = b."rack" THEN 0.06
            ELSE 0.005 END AS "c_ij"
FROM "vse_throughput" a, "vse_throughput" b
GROUP BY a."node_id", b."node_id", a."rack", b."rack"
PARTITIONED BY ALL
CLUSTERED BY "i", "j";

-- The optimizer's two flat vectors: the throughputs in node order, and
-- the contention matrix in row-major order.
REPLACE INTO vse_mu OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("mu" AS VARCHAR), 8192), ',') AS "mu"
FROM "vse_throughput"
PARTITIONED BY ALL;

REPLACE INTO vse_cov_flat OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("c_ij" AS VARCHAR), 65536), ',') AS "cov"
FROM "vse_contention"
PARTITIONED BY ALL;

REPLACE INTO vse_result OVERWRITE ALL
SELECT fractal_optimize_portfolio(a."mu", b."cov", 6) AS "rj"
FROM "vse_mu" a, "vse_cov_flat" b
PARTITIONED BY ALL;

SELECT fractal_json_value("rj", '$.sharpe') AS "sharpe" FROM "vse_result" GROUP BY "rj";

-- The chosen nodes: the ones with a non-zero weight.
REPLACE INTO vse_weights OVERWRITE ALL
SELECT t.i + 1 AS "node_id",
       fractal_json_value(o."rj", CONCAT('$.weights[', t.i, ']')) AS "weight"
FROM "vse_result" o, UNNEST(ARRAY[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
                                       13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                                       23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
                                       33, 34, 35, 36, 37, 38, 39, 40, 41, 42,
                                       43, 44, 45, 46, 47, 48, 49]) AS t(i)
GROUP BY t.i, o."rj"
PARTITIONED BY ALL;

SELECT w."node_id" AS "node_id", n."node_name" AS "node_name",
       ROUND(w."weight", 6) AS "weight"
FROM "vse_weights" w, "vse_nodes" n
WHERE n."id" = w."node_id" AND w."weight" > 0.000001
GROUP BY w."node_id", n."node_name", w."weight"
ORDER BY w."weight" DESC;

-- ---------------------------------------------------------------------------
-- 6. Reasoning: narrate the placement decision.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'given this cardinality-constrained node allocation (sharpe + weights per node), explain the placement decision and any risk from rack co-location',
    '{"sharpe":"' || (SELECT fractal_json_text("rj", '$.sharpe')
                      FROM "vse_result" GROUP BY "rj")
     || '","nodes":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CONCAT(n."node_name", ':',
                     ROUND(w."weight", 4)), 8192), ',')
                       FROM "vse_weights" w, "vse_nodes" n
                       WHERE n."id" = w."node_id" AND w."weight" > 0.000001)
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 7. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. The grid is a real 20x20 layout,
-- the sniper search found a node to place the workload on, and the
-- allocator chose exactly six nodes with a positive Sharpe.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "vse_nodes") = 50
            AND (SELECT fractal_dimension_boxcount("cloud", 2) FROM "vse_cloud") > 1.0
            AND (SELECT COUNT(*) FROM "vse_assign" WHERE "doc_id" IS NOT NULL) = 5
            AND (SELECT COUNT(*) FROM "vse_weights" WHERE "weight" > 0.000001) = 6
            AND (SELECT fractal_json_value("rj", '$.sharpe')
                  FROM "vse_result" GROUP BY "rj") > 0
            THEN 'HEADLINE kit=sovereign-edge-ai ok'
            ELSE 'HEADLINE kit=sovereign-edge-ai FAILED'
       END AS "headline";
