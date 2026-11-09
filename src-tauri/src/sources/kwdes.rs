//! 酷我 `mobi.s` 接口使用的 **改造版 DES**。
//!
//! SPDX-License-Identifier: LGPL-3.0-only
//!
//! 本文件移植自 [`@unblockneteasemusic/server`](https://github.com/UnblockNeteaseMusic/server)
//! v0.27.10 的 `src/kwDES.js`（Copyright (c) nondanee, 1715173329, pan93412），
//! 其算法又源自 [XuShaohua/kwplayer](https://github.com/XuShaohua/kwplayer) 与
//! [Levi233/MusicPlayer](https://github.com/Levi233/MusicPlayer)。
//! 许可证全文见仓库根目录 `licenses/LGPL-3.0-only.txt` 与 `THIRD_PARTY_LICENSES.md`。
//!
//! 与标准 DES 的差异：E 表被修改（最后一组为 `27,28,29,30,31,30`），
//! 且使用自定义 S 盒矩阵，因此 **不能** 直接使用标准 DES 库。
//!
//! 上游实现只使用加密（`encrypt`），且其 `decrypt` 与加密并 **非互逆**
//! （缺少 DES 收尾的 L/R 交换），因此本移植只保留加密路径。

const ARRAY_E: [i64; 64] = [
    31, 0, 1, 2, 3, 4, -1, -1, 3, 4, 5, 6, 7, 8, -1, -1, 7, 8, 9, 10, 11, 12, -1, -1, 11, 12, 13,
    14, 15, 16, -1, -1, 15, 16, 17, 18, 19, 20, -1, -1, 19, 20, 21, 22, 23, 24, -1, -1, 23, 24, 25,
    26, 27, 28, -1, -1, 27, 28, 29, 30, 31, 30, -1, -1,
];

const ARRAY_IP: [i64; 64] = [
    57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63,
    55, 47, 39, 31, 23, 15, 7, 56, 48, 40, 32, 24, 16, 8, 0, 58, 50, 42, 34, 26, 18, 10, 2, 60, 52,
    44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6,
];

const ARRAY_IP_1: [i64; 64] = [
    39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26,
    33, 1, 41, 9, 49, 17, 57, 25, 32, 0, 40, 8, 48, 16, 56, 24,
];

const ARRAY_LS: [u32; 16] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];

const ARRAY_LS_MASK: [u64; 3] = [0, 0x100001, 0x300003];

const ARRAY_P: [i64; 32] = [
    15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9, 1, 7, 23, 13, 31, 26, 2, 8, 18, 12,
    29, 5, 21, 10, 3, 24,
];

const ARRAY_PC_1: [i64; 56] = [
    56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59,
    51, 43, 35, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28,
    20, 12, 4, 27, 19, 11, 3,
];

const ARRAY_PC_2: [i64; 64] = [
    13, 16, 10, 23, 0, 4, -1, -1, 2, 27, 14, 5, 20, 9, -1, -1, 22, 18, 11, 3, 25, 7, -1, -1, 15, 6,
    26, 19, 12, 1, -1, -1, 40, 51, 30, 36, 46, 54, -1, -1, 29, 39, 50, 44, 32, 47, -1, -1, 43, 48,
    38, 55, 33, 52, -1, -1, 45, 41, 49, 35, 28, 31, -1, -1,
];

const MATRIX_NS_BOX: [[u8; 64]; 8] = [
    [
        14, 4, 3, 15, 2, 13, 5, 3, 13, 14, 6, 9, 11, 2, 0, 5, 4, 1, 10, 12, 15, 6, 9, 10, 1, 8, 12,
        7, 8, 11, 7, 0, 0, 15, 10, 5, 14, 4, 9, 10, 7, 8, 12, 3, 13, 1, 3, 6, 15, 12, 6, 11, 2, 9,
        5, 0, 4, 2, 11, 14, 1, 7, 8, 13,
    ],
    [
        15, 0, 9, 5, 6, 10, 12, 9, 8, 7, 2, 12, 3, 13, 5, 2, 1, 14, 7, 8, 11, 4, 0, 3, 14, 11, 13,
        6, 4, 1, 10, 15, 3, 13, 12, 11, 15, 3, 6, 0, 4, 10, 1, 7, 8, 4, 11, 14, 13, 8, 0, 6, 2, 15,
        9, 5, 7, 1, 10, 12, 14, 2, 5, 9,
    ],
    [
        10, 13, 1, 11, 6, 8, 11, 5, 9, 4, 12, 2, 15, 3, 2, 14, 0, 6, 13, 1, 3, 15, 4, 10, 14, 9, 7,
        12, 5, 0, 8, 7, 13, 1, 2, 4, 3, 6, 12, 11, 0, 13, 5, 14, 6, 8, 15, 2, 7, 10, 8, 15, 4, 9,
        11, 5, 9, 0, 14, 3, 10, 7, 1, 12,
    ],
    [
        7, 10, 1, 15, 0, 12, 11, 5, 14, 9, 8, 3, 9, 7, 4, 8, 13, 6, 2, 1, 6, 11, 12, 2, 3, 0, 5,
        14, 10, 13, 15, 4, 13, 3, 4, 9, 6, 10, 1, 12, 11, 0, 2, 5, 0, 13, 14, 2, 8, 15, 7, 4, 15,
        1, 10, 7, 5, 6, 12, 11, 3, 8, 9, 14,
    ],
    [
        2, 4, 8, 15, 7, 10, 13, 6, 4, 1, 3, 12, 11, 7, 14, 0, 12, 2, 5, 9, 10, 13, 0, 3, 1, 11, 15,
        5, 6, 8, 9, 14, 14, 11, 5, 6, 4, 1, 3, 10, 2, 12, 15, 0, 13, 2, 8, 5, 11, 8, 0, 15, 7, 14,
        9, 4, 12, 7, 10, 9, 1, 13, 6, 3,
    ],
    [
        12, 9, 0, 7, 9, 2, 14, 1, 10, 15, 3, 4, 6, 12, 5, 11, 1, 14, 13, 0, 2, 8, 7, 13, 15, 5, 4,
        10, 8, 3, 11, 6, 10, 4, 6, 11, 7, 9, 0, 6, 4, 2, 13, 1, 9, 15, 3, 8, 15, 3, 1, 14, 12, 5,
        11, 0, 2, 12, 14, 7, 5, 10, 8, 13,
    ],
    [
        4, 1, 3, 10, 15, 12, 5, 0, 2, 11, 9, 6, 8, 7, 6, 9, 11, 4, 12, 15, 0, 3, 10, 5, 14, 13, 7,
        8, 13, 14, 1, 2, 13, 6, 14, 9, 4, 1, 2, 14, 11, 13, 5, 0, 1, 10, 8, 3, 0, 11, 3, 5, 9, 4,
        15, 2, 7, 8, 12, 15, 10, 7, 6, 12,
    ],
    [
        13, 7, 10, 0, 6, 9, 5, 15, 8, 4, 3, 10, 11, 14, 12, 5, 2, 11, 9, 6, 15, 12, 0, 3, 4, 1, 14,
        13, 1, 2, 7, 8, 1, 2, 12, 15, 10, 4, 0, 3, 13, 14, 6, 9, 7, 8, 9, 6, 15, 1, 5, 12, 3, 10,
        14, 5, 8, 7, 11, 0, 4, 13, 2, 11,
    ],
];

const SECRET_KEY: [u8; 8] = *b"ylzsxkwm";

/// `arrayMask[i] = 2^i`（上游 `arrayMask[63] = -2^63`，二补码等价）。
fn mask(i: usize) -> u64 {
    1u64 << i
}

/// 位变换：把 `src` 中被 `table` 选中的位置重新排布到 `0..n`。
fn bit_transform(table: &[i64], n: usize, src: u64) -> u64 {
    let mut out = 0u64;
    for (i, &idx) in table.iter().take(n).enumerate() {
        if idx < 0 {
            continue;
        }
        let idx = idx as usize;
        if src & mask(idx) == 0 {
            continue;
        }
        out |= mask(i);
    }
    out
}

/// 单个 64 位分组的核心变换。
fn des64(sub_keys: &[u64; 16], block: u64) -> u64 {
    let out = bit_transform(&ARRAY_IP, 64, block);
    let mut p0 = out & 0xffff_ffff;
    let mut p1 = (out & 0xffff_ffff_0000_0000) >> 32;

    for &sub_key in sub_keys.iter() {
        let mut s_out = 0u64;
        let mut r = p1;
        r = bit_transform(&ARRAY_E, 64, r);
        r ^= sub_key;

        let mut p_r = [0u64; 8];
        for (j, slot) in p_r.iter_mut().enumerate() {
            *slot = (r >> (j * 8)) & 0xff;
        }
        for sbi in (0..8).rev() {
            s_out = (s_out << 4) | MATRIX_NS_BOX[sbi][p_r[sbi] as usize] as u64;
        }

        let r = bit_transform(&ARRAY_P, 32, s_out);
        let l = p0;
        p0 = p1;
        p1 = l ^ r;
    }

    // 上游在收尾处会 `pSource.reverse()`，即交换 L / R 后再拼接
    let combined = ((p0 << 32) & 0xffff_ffff_0000_0000) | (p1 & 0xffff_ffff);
    bit_transform(&ARRAY_IP_1, 64, combined)
}

/// 生成 16 组子密钥（仅加密方向）。
fn sub_keys(key: u64) -> [u64; 16] {
    let mut l2 = bit_transform(&ARRAY_PC_1, 56, key);
    let mut keys = [0u64; 16];
    for (i, &ls) in ARRAY_LS.iter().enumerate() {
        let m = ARRAY_LS_MASK[ls as usize];
        l2 = ((l2 & m) << (28 - ls)) | ((l2 & !m) >> ls);
        keys[i] = bit_transform(&ARRAY_PC_2, 64, l2);
    }
    keys
}

/// 加密（对应上游 `crypt(msg, key, 0)`）。
///
/// 输出长度与上游一致：`(floor(len / 8) + 1) * 8` 字节，
/// 即不足 8 字节的尾部会补零并单独成块。
fn crypt(msg: &[u8], key: &[u8; 8]) -> Vec<u8> {
    let mut key_block = 0u64;
    for (i, b) in key.iter().enumerate() {
        key_block |= (*b as u64) << (i * 8);
    }
    let keys = sub_keys(key_block);

    let j = msg.len() / 8;
    let mut out = Vec::with_capacity((j + 1) * 8);

    for m in 0..j {
        let mut block = 0u64;
        for n in 0..8 {
            block |= (msg[n + m * 8] as u64) << (n * 8);
        }
        // 上游按 `l3.shiftRight(i6 * 8)` 逐字节输出，即 **低位在前**（小端）
        out.extend_from_slice(&des64(&keys, block).to_le_bytes());
    }

    // 尾部不足 8 字节：补零后单独加密一块
    let tail = &msg[j * 8..];
    let mut tail_block = 0u64;
    for (i, b) in tail.iter().enumerate() {
        tail_block |= (*b as u64) << (i * 8);
    }
    out.extend_from_slice(&des64(&keys, tail_block).to_le_bytes());
    out
}

/// 酷我查询串加密（改造版 DES + Base64）。
pub fn encrypt_query(query: &str) -> String {
    use base64::Engine;
    let encrypted = crypt(query.as_bytes(), &SECRET_KEY);
    base64::engine::general_purpose::STANDARD.encode(encrypted)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 与上游 Node 实现（`@unblockneteasemusic/server@0.27.10` 的 `src/kwDES.js`）
    /// 独立交叉验证得到的固定向量。
    ///
    /// 上游 `encryptQuery` 输出：
    /// `NI8S5evAnmHH4UXcuKKslDk4RFzONrTj1BvCoyMODMTUvpQlWnft3Eccd/NC9JdLFsVy/tvCgksRUHX6eSWQFEXV3zZS3yrqb2ASAUwCJKYLJ6ShYiU19qWNmoyxI7Y+m0Vtdpd536R8HDfJnz/h9Q==`
    #[test]
    fn matches_upstream_node_vector() {
        let query = "corp=kuwo&source=kwplayer_ar_5.1.0.0_B_jiakong_vh.apk&p2p=1&type=convert_url2&sig=0&format=mp3&rid=474678847";
        let got = encrypt_query(query);
        assert_eq!(
            got,
            "NI8S5evAnmHH4UXcuKKslDk4RFzONrTj1BvCoyMODMTUvpQlWnft3Eccd/NC9JdLFsVy/tvCgksRUHX6eSWQFEXV3zZS3yrqb2ASAUwCJKYLJ6ShYiU19qWNmoyxI7Y+m0Vtdpd536R8HDfJnz/h9Q=="
        );
    }

    /// 直接比较原始字节（hex），避免 base64 换行造成的歧义。
    #[test]
    fn matches_upstream_node_ciphertext_bytes() {
        let query = "corp=kuwo&source=kwplayer_ar_5.1.0.0_B_jiakong_vh.apk&p2p=1&type=convert_url2&sig=0&format=mp3&rid=474678847";
        let expected = "348f12e5ebc09e61c7e145dcb8a2ac943938445cce36b4e3d41bc2a3230e0cc4d4be94255a77eddc471c77f342f4974b16c572fedbc2824b115075fa7925901445d5df3652df2aea6f6012014c0224a60b27a4a1622535f6a58d9a8cb123b63e9b456d769779dfa47c1c37c99f3fe1f5";
        let got = hex::encode(crypt(query.as_bytes(), &SECRET_KEY));
        assert_eq!(got, expected);
    }

    /// 分块长度与上游一致：`floor(len / 8) + 1` 块。
    #[test]
    fn matches_upstream_block_lengths() {
        let cases: [(usize, &str); 6] = [
            (1, "95107a178705ab6e"),
            (7, "d0c036b161b787db"),
            (8, "6effb2513e0421996a63488853e41dd1"),
            (9, "6effb2513e04219995107a178705ab6e"),
            (16, "6effb2513e0421996effb2513e0421996a63488853e41dd1"),
            (100, "6effb2513e0421996effb2513e0421996effb2513e0421996effb2513e0421996effb2513e0421996effb2513e0421996effb2513e0421996effb2513e0421996effb2513e0421996effb2513e0421996effb2513e0421996effb2513e0421999603d9abd993cfba"),
        ];
        for (len, expected) in cases {
            let msg = vec![0x41u8; len];
            let got = hex::encode(crypt(&msg, &SECRET_KEY));
            assert_eq!(got, expected, "长度 {} 的密文不匹配", len);
        }
    }

    #[test]
    fn encrypt_is_deterministic() {
        let q = "corp=kuwo&type=convert_url2&rid=474678847";
        assert_eq!(encrypt_query(q), encrypt_query(q));
    }

    #[test]
    fn output_has_no_plaintext_leak() {
        let q = "corp=kuwo&type=convert_url2";
        let enc = encrypt_query(q);
        assert!(!enc.contains("kuwo"));
    }
}
