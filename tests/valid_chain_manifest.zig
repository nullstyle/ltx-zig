pub const CaseKind = enum(u8) {
    checked_grow_512,
    checked_sparse_shrink_4096,
    no_checksum_max_page_shrink_65536,
    checked_delete_1024,
    legacy_current_512,
};

pub const all = [_]CaseKind{
    .checked_grow_512,
    .checked_sparse_shrink_4096,
    .no_checksum_max_page_shrink_65536,
    .checked_delete_1024,
    .legacy_current_512,
};

pub const total_input_count = count: {
    var count: usize = 0;
    for (all) |kind| count += input_count(kind);
    break :count count;
};

pub fn name(kind: CaseKind) []const u8 {
    return switch (kind) {
        .checked_grow_512 => "checked-grow-512",
        .checked_sparse_shrink_4096 => "checked-sparse-shrink-4096",
        .no_checksum_max_page_shrink_65536 => "no-checksum-max-page-shrink-65536",
        .checked_delete_1024 => "checked-delete-1024",
        .legacy_current_512 => "legacy-current-512",
    };
}

pub fn input_count(kind: CaseKind) usize {
    return switch (kind) {
        .checked_grow_512, .checked_sparse_shrink_4096 => 3,
        .no_checksum_max_page_shrink_65536,
        .checked_delete_1024,
        .legacy_current_512,
        => 2,
    };
}

pub fn index(kind: CaseKind) usize {
    for (all, 0..) |candidate, case_index| {
        if (candidate == kind) return case_index;
    }
    unreachable;
}
