#[test_only]
module altheia_sui_demo::deepbook_adapter_tests;

use altheia_sui_demo::deepbook_adapter;

// Pure scaling math (testnet-verified: mid_price 794000, SUI base_scalar 1e9
// -> SUI ~ 0.794 DBUSDC). The pool-reading attest is integration-tested.

#[test]
fun min_out_scaling() {
    assert!(deepbook_adapter::compute_min_out(1_000_000_000, 794_000, 1_000_000_000, 0) == 794_000, 0);
    assert!(deepbook_adapter::compute_min_out(1_000_000_000, 794_000, 1_000_000_000, 100) == 786_060, 1);
    assert!(deepbook_adapter::compute_min_out(500_000_000, 794_000, 1_000_000_000, 0) == 397_000, 2);
}

#[test]
fun min_out_zero_amount() {
    assert!(deepbook_adapter::compute_min_out(0, 794_000, 1_000_000_000, 100) == 0, 0);
}

#[test]
fun min_out_no_overflow() {
    assert!(deepbook_adapter::compute_min_out(1_000_000_000_000, 794_000, 1_000_000_000, 50) == 790_030_000, 0);
}
