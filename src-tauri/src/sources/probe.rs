// SPDX-License-Identifier: LGPL-3.0-only
// 移植自 @unblockneteasemusic/server v0.27.10 的 decode() (Copyright (c) nondanee, 1715173329, pan93412)
// 详见 ../../THIRD_PARTY_LICENSES.md 与 licenses/LGPL-3.0-only.txt

//! 从音频字节探测码率（移植上游 `@unblockneteasemusic/server` 的 `decode`）。

/// MPEG 码率表（kbps）。索引顺序：版本 -> 层 -> 码率索引。
/// 版本：3 = MPEG1，2 = MPEG2，0 = MPEG2.5；层：3 = Layer I，2 = Layer II，1 = Layer III。
const MPEG1: [[u16; 16]; 4] = [
    [0; 16],
    [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
    ],
    [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0,
    ],
    [
        0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0,
    ],
];

const MPEG2: [[u16; 16]; 4] = [
    [0; 16],
    [
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
    ],
    [
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
    ],
    [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0,
    ],
];

/// 探测音频码率（kbps）。识别不了时返回 `None`。
pub fn detect_bitrate_kbps(data: &[u8]) -> Option<u16> {
    if data.len() >= 4 && &data[0..4] == b"fLaC" {
        // FLAC：上游按 999 kbps 处理
        return Some(999);
    }
    let mut pointer = 0usize;
    if data.len() >= 3 && &data[0..3] == b"ID3" {
        pointer = 6;
        if data.len() < pointer + 4 {
            return None;
        }
        // ID3v2 size 是 syncsafe integer。
        // 注意：上游用的是「累计左移」写法（每次都基于上一次的结果左移），
        // 这里必须与上游保持一致，否则偏移会不同。
        let mut size: u64 = 0;
        for i in 0..4 {
            size = size
                .saturating_add((data[pointer + i] as u64) & 0x7f)
                .saturating_mul(1u64 << (7 * (3 - i)));
        }
        pointer = 10 + size as usize;
    }
    if data.len() < pointer + 4 {
        return None;
    }
    let header = &data[pointer..pointer + 4];
    // MPEG 帧同步校验
    if header[0] != 0xff
        || ((header[1] >> 5) & 0x7) != 0x7
        || ((header[1] >> 1) & 0x3) == 0
        || ((header[2] >> 4) & 0xf) == 0xf
        || ((header[2] >> 2) & 0x3) == 0x3
    {
        return None;
    }
    let version = ((header[1] >> 3) & 0x3) as usize;
    let layer = ((header[1] >> 1) & 0x3) as usize;
    let bitrate_index = (header[2] >> 4) as usize;

    let table: &[[u16; 16]; 4] = match version {
        3 => &MPEG1,
        2 => &MPEG2,
        0 => &MPEG2,
        _ => return None,
    };
    if layer == 0 || layer > 3 || bitrate_index > 15 {
        return None;
    }
    // MPEG2 的 Layer III 复用 Layer II 行
    let row = if version != 3 && layer == 1 { 2 } else { layer };
    let kbps = table[row][bitrate_index];
    if kbps == 0 {
        None
    } else {
        Some(kbps)
    }
}

/// 探测音频码率（bps）。
pub fn detect_bitrate_bps(data: &[u8]) -> Option<i64> {
    detect_bitrate_kbps(data).map(|k| k as i64 * 1000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_flac() {
        assert_eq!(detect_bitrate_kbps(b"fLaC\x00\x00\x00\x22"), Some(999));
    }

    #[test]
    fn detects_mpeg1_layer3_320() {
        // 0xFF 0xFB = MPEG1 Layer III, 0x90 -> bitrate index 9 => 128kbps
        let header = [0xff, 0xfb, 0x90, 0x00];
        assert_eq!(detect_bitrate_kbps(&header), Some(128));
    }

    #[test]
    fn detects_mpeg1_layer3_192() {
        // 0xFF 0xFB = MPEG1 Layer III, 0xC0 -> bitrate index 12 => 224kbps
        let header = [0xff, 0xfb, 0xc0, 0x00];
        assert_eq!(detect_bitrate_kbps(&header), Some(224));
    }

    #[test]
    fn detects_mpeg1_layer3_320_kbps() {
        // 0xFF 0xFB 0xE0 -> index 14 => 320kbps
        let header = [0xff, 0xfb, 0xe0, 0x00];
        assert_eq!(detect_bitrate_kbps(&header), Some(320));
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(detect_bitrate_kbps(&[0x00, 0x01, 0x02, 0x03]), None);
        assert_eq!(detect_bitrate_kbps(b""), None);
    }

    #[test]
    fn id3_tag_is_skipped() {
        // ID3v2.3 头部 10 字节，synchsafe size = 10（上游累计写法得到 10）
        // => 音频帧从偏移 20 开始，因此需要 10 字节头 + 10 字节标签体 + 4 字节帧
        let mut data = vec![0u8; 10];
        data[0..3].copy_from_slice(b"ID3");
        data[3] = 3;
        data[6] = 0;
        data[7] = 0;
        data[8] = 0;
        data[9] = 10;
        data.extend_from_slice(&[0u8; 10]); // 标签体
        data.extend_from_slice(&[0xff, 0xfb, 0x90, 0x00]); // MPEG1 Layer III 128kbps
        assert_eq!(detect_bitrate_kbps(&data), Some(128));
    }

    #[test]
    fn id3_tag_truncated_returns_none() {
        let mut data = vec![0u8; 10];
        data[0..3].copy_from_slice(b"ID3");
        data[9] = 10;
        data.extend_from_slice(&[0xff, 0xfb, 0x90, 0x00]);
        assert_eq!(detect_bitrate_kbps(&data), None);
    }
}
