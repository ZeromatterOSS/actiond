def actiond_zigopts():
    return select({
        "//:compilation_mode_opt": [
            "-O",
            "ReleaseFast",
        ],
        "//conditions:default": [],
    })
