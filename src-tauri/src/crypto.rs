// SPDX-License-Identifier: MIT
// 移植自 NeteaseCloudMusicApi (Copyright (c) 2013-2022 Binaryify) 及其增强分支 neteasecloudmusicapienhanced/api-enhanced
// 详见 ../../THIRD_PARTY_LICENSES.md

//! 网易云音乐接口加密实现。
//!
//! 参考上游 `neteasecloudmusicapienhanced/api-enhanced` 的 `util/crypto.js`：
//! - `weapi`：双层 AES-128-CBC + RSA **raw/no-padding** 加密 `encSecKey`
//! - `eapi` ：AES-128-ECB（PKCS#7 padding），密文以大写 HEX 传输
//! - `linuxapi`：AES-128-ECB，备用
//!
//! 上游 `iv` 常量 `0102030405060708` 是 **16 字节 ASCII 字符串**，不是 8 字节 hex。

use aes::cipher::block_padding::Pkcs7;
use aes::cipher::{BlockDecryptMut, BlockEncryptMut, KeyInit, KeyIvInit};
use base64::Engine;
use md5::{Digest, Md5};
use num_bigint::BigUint;
use num_traits::Zero;

/// eapi AES-128-ECB 密钥
pub const EAPI_KEY: &[u8; 16] = b"e82ckenh8dichen8";
/// linuxapi AES-128-ECB 密钥
pub const LINUXAPI_KEY: &[u8; 16] = b"rFgB&h#%2?^eDg:Q";
/// weapi 第一层 AES-128-CBC 固定密钥
pub const WEAPI_PRESET_KEY: &[u8; 16] = b"0CoJUm6Qyw8W8jud";
/// weapi AES-128-CBC 初始向量（16 字节 ASCII）
pub const WEAPI_IV: &[u8; 16] = b"0102030405060708";

/// weapi `encSecKey` 使用的 1024 位 RSA 公钥模数（十六进制，256 个字符）。
///
/// 该值由 `openssl rsa -pubin -modulus` 从上游 PEM 公钥直接导出，
/// 末尾为 `...db0a22b8e7`；**不可**把 DER 结构里的 `0203010001`（e = 65537）并入。
pub const WEAPI_RSA_N_HEX: &str = "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7";
/// weapi `encSecKey` 公钥指数
pub const WEAPI_RSA_E: u32 = 65537;

const BASE62: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;
type Aes128CbcDec = cbc::Decryptor<aes::Aes128>;
type Aes128EcbEnc = ecb::Encryptor<aes::Aes128>;
type Aes128EcbDec = ecb::Decryptor<aes::Aes128>;

/// 计算小写十六进制 MD5。
pub fn md5_hex(data: &[u8]) -> String {
    let mut hasher = Md5::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

/// AES-128-CBC 加密（PKCS#7 padding），输出标准 Base64。
pub fn aes_cbc_encrypt_b64(plaintext: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> String {
    let cipher = Aes128CbcEnc::new_from_slices(key, iv).expect("valid AES-128-CBC params");
    let ct = cipher.encrypt_padded_vec_mut::<Pkcs7>(plaintext);
    base64::engine::general_purpose::STANDARD.encode(ct)
}

/// AES-128-CBC 解密（PKCS#7 padding），输入为标准 Base64。
pub fn aes_cbc_decrypt_b64(ciphertext_b64: &str, key: &[u8; 16], iv: &[u8; 16]) -> Option<Vec<u8>> {
    let raw = base64::engine::general_purpose::STANDARD
        .decode(ciphertext_b64)
        .ok()?;
    let cipher = Aes128CbcDec::new_from_slices(key, iv).ok()?;
    cipher.decrypt_padded_vec_mut::<Pkcs7>(&raw).ok()
}

/// AES-128-ECB 加密（PKCS#7 padding），输出 **大写 HEX**。
pub fn aes_ecb_encrypt_hex_upper(plaintext: &[u8], key: &[u8; 16]) -> String {
    let cipher = Aes128EcbEnc::new_from_slice(key).expect("valid AES-128-ECB key");
    let ct = cipher.encrypt_padded_vec_mut::<Pkcs7>(plaintext);
    let mut out = String::with_capacity(ct.len() * 2);
    for b in ct {
        out.push_str(&format!("{:02X}", b));
    }
    out
}

/// AES-128-ECB 解密，输入为大写/小写 HEX。
pub fn aes_ecb_decrypt_hex(ciphertext_hex: &str, key: &[u8; 16]) -> Option<Vec<u8>> {
    let raw = hex::decode(ciphertext_hex.trim()).ok()?;
    let cipher = Aes128EcbDec::new_from_slice(key).ok()?;
    cipher.decrypt_padded_vec_mut::<Pkcs7>(&raw).ok()
}

/// 生成 16 位 base62 随机密钥（上游 `weapi` 使用）。
pub fn random_base62_16() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    (0..16)
        .map(|_| BASE62[rng.gen_range(0..BASE62.len())] as char)
        .collect()
}

/// 生成 N 字节随机 hex 字符串。
pub fn random_hex(bytes: usize) -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    (0..bytes)
        .map(|_| format!("{:02x}", rng.gen::<u8>()))
        .collect()
}

/// 生成网易云客户端风格的 52 位十六进制 `deviceId`。
pub fn generate_device_id() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    (0..52)
        .map(|_| {
            let v = rng.gen_range(0..16);
            char::from_digit(v, 16).unwrap_or('0').to_ascii_uppercase()
        })
        .collect()
}

/// **Raw RSA（NoPadding）加密**，输出小写 hex，左侧补零到 256 个字符。
///
/// 上游使用 `node-forge` 的 `publicKey.encrypt(str, 'NONE')`，即 *不做 PKCS#1 填充*，
/// 直接把明文当作大端整数做 `c = m^e mod n`。因此 **不能** 使用 `rsa` crate 的
/// `Pkcs1v15Encrypt`——那会引入 0x00 02 前缀并改变密文。
pub fn raw_rsa_encrypt_hex(message: &[u8]) -> String {
    let n = BigUint::parse_bytes(WEAPI_RSA_N_HEX.as_bytes(), 16).expect("invalid RSA modulus");
    let e = BigUint::from(WEAPI_RSA_E);
    let m = BigUint::from_bytes_be(message);
    let c = if m.is_zero() {
        BigUint::zero()
    } else {
        m.modpow(&e, &n)
    };
    let bytes = c.to_bytes_be();
    // 模数 1024 位 => 128 字节 => 256 个 hex 字符
    let mut out = vec![0u8; 128usize.saturating_sub(bytes.len())];
    out.extend_from_slice(&bytes);
    hex::encode(out)
}

/// eapi 加密：返回 `params`（大写 HEX）。
pub fn eapi_encrypt(url: &str, data: &serde_json::Value) -> String {
    let text = serde_json::to_string(data).expect("serialize eapi payload");
    let message = format!("nobody{}use{}md5forencrypt", url, text);
    let digest = md5_hex(message.as_bytes());
    let plain = format!("{}-36cd479b6b5-{}-36cd479b6b5-{}", url, text, digest);
    aes_ecb_encrypt_hex_upper(plain.as_bytes(), EAPI_KEY)
}

/// eapi 响应解密（上游 `encryptResponse` 默认关闭，这里保留以防上游变更）。
pub fn eapi_res_decrypt(encrypted_hex: &str) -> Option<serde_json::Value> {
    let plain = aes_ecb_decrypt_hex(encrypted_hex, EAPI_KEY)?;
    serde_json::from_slice(&plain).ok()
}

/// weapi 加密结果。
#[derive(Debug, Clone)]
pub struct WeapiPayload {
    /// 双层 AES-CBC 后的 base64
    pub params: String,
    /// raw RSA 加密的翻转密钥（hex）
    pub enc_sec_key: String,
}

/// weapi 加密：双层 AES-128-CBC + raw RSA。
///
/// `secret_key` 可注入，便于测试固定向量。
pub fn weapi_encrypt_with_key(data: &serde_json::Value, secret_key: &str) -> WeapiPayload {
    let text = serde_json::to_string(data).expect("serialize weapi payload");
    let first = aes_cbc_encrypt_b64(text.as_bytes(), WEAPI_PRESET_KEY, WEAPI_IV);
    let mut key_bytes = [0u8; 16];
    let kb = secret_key.as_bytes();
    let n = kb.len().min(16);
    key_bytes[..n].copy_from_slice(&kb[..n]);
    let params = aes_cbc_encrypt_b64(first.as_bytes(), &key_bytes, WEAPI_IV);
    let reversed: String = secret_key.chars().rev().collect();
    let enc_sec_key = raw_rsa_encrypt_hex(reversed.as_bytes());
    WeapiPayload {
        params,
        enc_sec_key,
    }
}

/// weapi 加密（随机密钥）。
pub fn weapi_encrypt(data: &serde_json::Value) -> WeapiPayload {
    weapi_encrypt_with_key(data, &random_base62_16())
}

/// linuxapi 加密：返回 `eparams`（大写 HEX）。
pub fn linuxapi_encrypt(data: &serde_json::Value) -> String {
    let text = serde_json::to_string(data).expect("serialize linuxapi payload");
    aes_ecb_encrypt_hex_upper(text.as_bytes(), LINUXAPI_KEY)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 固定测试密钥（必须为 16 字节，对应上游 `weapi` 的 base62 密钥长度）。
    const TEST_KEY: &str = "aB3xY9zQ1mN0pL2k";

    fn test_key_bytes() -> [u8; 16] {
        let mut out = [0u8; 16];
        out.copy_from_slice(TEST_KEY.as_bytes());
        out
    }

    /// 与 `openssl pkeyutl -pkeyopt rsa_padding_mode:none` 交叉验证过的 raw RSA 向量。
    const RAW_RSA_VECTOR: &str = concat!(
        "5bbbc62c5315c08bc114fc568dd29023aa6894b00876ae63983fddf0e29c03f7",
        "1e971bf682cd18cfbf825baa40f7446afa77e2c1ecb0d6b294f915dad40c0c1a",
        "4fb0808781b825c21990bb216ef28f497ead1459b8a535bde537aa258013617a",
        "f562ebbe02905f9c12e1d516692ed04492f3baec00088240405d5ae905bcad64"
    );

    #[test]
    fn rsa_modulus_is_valid() {
        // 模数必须是 1024 位（256 个 hex 字符），且不含 DER 尾部
        assert_eq!(WEAPI_RSA_N_HEX.len(), 256);
        assert!(WEAPI_RSA_N_HEX.ends_with("b8e7"));
        assert!(!WEAPI_RSA_N_HEX.contains("0203010001"));
        let n = BigUint::parse_bytes(WEAPI_RSA_N_HEX.as_bytes(), 16).unwrap();
        assert_eq!(n.bits(), 1024);
    }

    #[test]
    fn raw_rsa_matches_openssl_reference() {
        let reversed: String = TEST_KEY.chars().rev().collect();
        assert_eq!(reversed, "k2Lp0Nm1Qz9Yx3Ba");
        let got = raw_rsa_encrypt_hex(reversed.as_bytes());
        assert_eq!(got.len(), 256);
        assert_eq!(got, RAW_RSA_VECTOR);
    }

    /// AES-128-CBC NIST 向量（SP 800-38A F.2.1）。
    #[test]
    fn aes_cbc_matches_nist_vector() {
        let key: [u8; 16] = [
            0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf,
            0x4f, 0x3c,
        ];
        let iv: [u8; 16] = [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
            0x0e, 0x0f,
        ];
        let plain = [
            0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93,
            0x17, 0x2a,
        ];
        let b64 = aes_cbc_encrypt_b64(&plain, &key, &iv);
        let ct = base64::engine::general_purpose::STANDARD
            .decode(&b64)
            .unwrap();
        // 第一个密文块应与 NIST 一致（后面是 PKCS#7 填充块）
        assert_eq!(
            &ct[..16],
            &[
                0x76, 0x49, 0xab, 0xac, 0x81, 0x19, 0xb2, 0x46, 0xce, 0xe9, 0x8e, 0x9b, 0x12, 0xe9,
                0x19, 0x7d
            ]
        );
        let back = aes_cbc_decrypt_b64(&b64, &key, &iv).unwrap();
        assert_eq!(back, plain.to_vec());
    }

    /// AES-128-ECB NIST 向量（SP 800-38A F.1.1）。
    #[test]
    fn aes_ecb_matches_nist_vector() {
        let key: [u8; 16] = [
            0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf,
            0x4f, 0x3c,
        ];
        let plain = [
            0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93,
            0x17, 0x2a,
        ];
        let hex = aes_ecb_encrypt_hex_upper(&plain, &key);
        assert!(hex.starts_with("3AD77BB40D7A3660A89ECAF32466EF97"));
        let back = aes_ecb_decrypt_hex(&hex, &key).unwrap();
        assert_eq!(back, plain.to_vec());
    }

    #[test]
    fn weapi_constants_are_correct() {
        // 上游 iv 是 16 字节 ASCII 字符串
        assert_eq!(WEAPI_IV.len(), 16);
        assert_eq!(WEAPI_IV, b"0102030405060708");
        assert_eq!(WEAPI_PRESET_KEY, b"0CoJUm6Qyw8W8jud");
        assert_eq!(EAPI_KEY, b"e82ckenh8dichen8");
    }

    #[test]
    fn eapi_matches_reference_shape() {
        let data = json!({"ids": "[1]"});
        let got = eapi_encrypt("/api/song/enhance/player/url/v1", &data);
        // 同一输入必须稳定（eapi 无随机量）
        assert_eq!(got, eapi_encrypt("/api/song/enhance/player/url/v1", &data));
        assert!(got
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase()));
        assert_eq!(got.len() % 32, 0);
    }

    #[test]
    fn eapi_roundtrip() {
        let data = json!({"ids": "[1]", "level": "higher", "encodeType": "flac"});
        let url = "/api/song/enhance/player/url/v1";
        let text = serde_json::to_string(&data).unwrap();
        let digest = md5_hex(format!("nobody{}use{}md5forencrypt", url, text).as_bytes());
        let plain = format!("{}-36cd479b6b5-{}-36cd479b6b5-{}", url, text, digest);
        let ct = aes_ecb_encrypt_hex_upper(plain.as_bytes(), EAPI_KEY);
        let pt = aes_ecb_decrypt_hex(&ct, EAPI_KEY).unwrap();
        assert_eq!(String::from_utf8(pt).unwrap(), plain);
    }

    /// weapi：固定密钥时 `encSecKey` 必须与 raw RSA 向量一致，
    /// 且 `params` 的解密顺序必须是「先 secretKey，后 presetKey」。
    #[test]
    fn weapi_fixed_key_vector() {
        let payload = weapi_encrypt_with_key(&json!({}), TEST_KEY);
        assert_eq!(payload.enc_sec_key, RAW_RSA_VECTOR);

        // 第一步：用 secretKey 解外层
        let outer = aes_cbc_decrypt_b64(&payload.params, &test_key_bytes(), WEAPI_IV).unwrap();
        let outer_text = String::from_utf8(outer).unwrap();
        // 第二步：用 presetKey 解内层
        let inner = aes_cbc_decrypt_b64(&outer_text, WEAPI_PRESET_KEY, WEAPI_IV).unwrap();
        assert_eq!(String::from_utf8(inner).unwrap(), "{}");
    }

    #[test]
    fn random_base62_has_16_chars() {
        let k = random_base62_16();
        assert_eq!(k.len(), 16);
        assert!(k.bytes().all(|b| BASE62.contains(&b)));
    }

    #[test]
    fn md5_known_vector() {
        assert_eq!(md5_hex(b"abc"), "900150983cd24fb0d6963f7d28e17f72");
    }
}
