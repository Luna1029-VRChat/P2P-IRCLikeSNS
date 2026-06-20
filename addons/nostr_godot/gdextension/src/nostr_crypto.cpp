#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/classes/engine.hpp>

#include <cstring>
#include <cstdlib>
#include <string>

extern "C" {
#include <secp256k1.h>
#include <secp256k1_schnorrsig.h>
#include <secp256k1_ecdh.h>
}

using namespace godot;

static secp256k1_context *s_ctx = nullptr;

static String hex_from_bytes(const unsigned char *data, size_t len) {
    static const char hex[] = "0123456789abcdef";
    std::string s;
    s.resize(len * 2);
    for (size_t i = 0; i < len; i++) {
        s[i * 2] = hex[data[i] >> 4];
        s[i * 2 + 1] = hex[data[i] & 0xf];
    }
    return String(s.c_str());
}

static PackedByteArray bytes_from_hex(const String &hex) {
    CharString cs = hex.utf8();
    const char *h = cs.get_data();
    size_t len = std::strlen(h);
    PackedByteArray arr;
    arr.resize(len / 2);
    uint8_t *w = arr.ptrw();
    for (size_t i = 0; i < len / 2; i++) {
        char hi = h[i * 2];
        char lo = h[i * 2 + 1];
        uint8_t b = 0;
        if (hi >= '0' && hi <= '9') b |= (hi - '0') << 4;
        else if (hi >= 'a' && hi <= 'f') b |= (hi - 'a' + 10) << 4;
        else if (hi >= 'A' && hi <= 'F') b |= (hi - 'A' + 10) << 4;
        if (lo >= '0' && lo <= '9') b |= (lo - '0');
        else if (lo >= 'a' && lo <= 'f') b |= (lo - 'a' + 10);
        else if (lo >= 'A' && lo <= 'F') b |= (lo - 'A' + 10);
        w[i] = b;
    }
    return arr;
}

class NostrCrypto : public Object {
    GDCLASS(NostrCrypto, Object)

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("derive_pubkey", "private_key_hex"), &NostrCrypto::derive_pubkey);
        ClassDB::bind_method(D_METHOD("schnorr_sign", "private_key_hex", "message"), &NostrCrypto::schnorr_sign);
        ClassDB::bind_method(D_METHOD("schnorr_sign_raw", "private_key", "message"), &NostrCrypto::schnorr_sign_raw);
        ClassDB::bind_method(D_METHOD("ecdh", "private_key_hex", "pubkey_hex"), &NostrCrypto::ecdh);
        ClassDB::bind_method(D_METHOD("generate_private_key"), &NostrCrypto::generate_private_key);
    }

public:
    String derive_pubkey(const String &private_key_hex) {
        PackedByteArray pk_bytes = bytes_from_hex(private_key_hex);
        if (pk_bytes.size() != 32) return String();

        secp256k1_keypair keypair;
        if (!secp256k1_keypair_create(s_ctx, &keypair, pk_bytes.ptr())) {
            return String();
        }

        secp256k1_xonly_pubkey xonly;
        if (!secp256k1_keypair_xonly_pub(s_ctx, &xonly, nullptr, &keypair)) {
            return String();
        }

        unsigned char pubkey_bytes[32];
        secp256k1_xonly_pubkey_serialize(s_ctx, pubkey_bytes, &xonly);
        return hex_from_bytes(pubkey_bytes, 32);
    }

    PackedByteArray schnorr_sign(const String &private_key_hex, const PackedByteArray &message) {
        PackedByteArray pk_bytes = bytes_from_hex(private_key_hex);
        if (pk_bytes.size() != 32 || message.size() != 32) return PackedByteArray();

        secp256k1_keypair keypair;
        if (!secp256k1_keypair_create(s_ctx, &keypair, pk_bytes.ptr())) {
            return PackedByteArray();
        }

        unsigned char sig[64];
        if (!secp256k1_schnorrsig_sign32(s_ctx, sig, message.ptr(), &keypair, nullptr)) {
            return PackedByteArray();
        }

        PackedByteArray result;
        result.resize(64);
        std::memcpy(result.ptrw(), sig, 64);
        return result;
    }

    PackedByteArray schnorr_sign_raw(const PackedByteArray &private_key, const PackedByteArray &message) {
        if (private_key.size() != 32 || message.size() != 32) return PackedByteArray();

        secp256k1_keypair keypair;
        if (!secp256k1_keypair_create(s_ctx, &keypair, private_key.ptr())) {
            return PackedByteArray();
        }

        unsigned char sig[64];
        if (!secp256k1_schnorrsig_sign32(s_ctx, sig, message.ptr(), &keypair, nullptr)) {
            return PackedByteArray();
        }

        PackedByteArray result;
        result.resize(64);
        std::memcpy(result.ptrw(), sig, 64);
        return result;
    }

    PackedByteArray ecdh(const String &private_key_hex, const String &pubkey_hex) {
        PackedByteArray sk_bytes = bytes_from_hex(private_key_hex);
        if (sk_bytes.size() != 32) return PackedByteArray();

        PackedByteArray pub_x = bytes_from_hex(pubkey_hex);
        if (pub_x.size() != 32) return PackedByteArray();

        // Build a compressed pubkey (02 || x) — Y parity doesn't matter for
        // ECDH since X coordinate of the shared point is the same either way.
        unsigned char serialized[33];
        serialized[0] = 0x02;
        std::memcpy(serialized + 1, pub_x.ptr(), 32);

        secp256k1_pubkey full_pubkey;
        if (!secp256k1_ec_pubkey_parse(s_ctx, &full_pubkey, serialized, 33)) {
            return PackedByteArray();
        }

        // shared_point = tweak * pubkey where tweak = our private key
        // This computes (priv * other_priv * G) — the ECDH shared point
        if (!secp256k1_ec_pubkey_tweak_mul(s_ctx, &full_pubkey, sk_bytes.ptr())) {
            return PackedByteArray();
        }

        // Serialize as uncompressed (04 || x || y, 65 bytes)
        unsigned char uncompressed[65];
        size_t output_len = 65;
        secp256k1_ec_pubkey_serialize(s_ctx, uncompressed, &output_len, &full_pubkey, SECP256K1_EC_UNCOMPRESSED);

        // Return just the 32-byte X coordinate — this is what
        // nostr-tools' NIP-04 uses as the AES key (no SHA256).
        PackedByteArray result;
        result.resize(32);
        std::memcpy(result.ptrw(), uncompressed + 1, 32);
        return result;
    }

    String generate_private_key() {
        unsigned char buf[32];
        for (int i = 0; i < 32; i++) {
            buf[i] = (unsigned char)(std::rand() % 256);
        }
        return hex_from_bytes(buf, 32);
    }
};

static NostrCrypto *singleton = nullptr;

extern "C" {
GDExtensionBool GDE_EXPORT gdextension_entry(
    GDExtensionInterfaceGetProcAddress p_get_proc_address,
    GDExtensionClassLibraryPtr p_library,
    GDExtensionInitialization *r_initialization
) {
    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer([](ModuleInitializationLevel p_level) {
        if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
        s_ctx = secp256k1_context_create(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY);
        ClassDB::register_class<NostrCrypto>();
        singleton = memnew(NostrCrypto);
        Engine::get_singleton()->register_singleton("NostrCrypto", singleton);
    });
    init_obj.register_terminator([](ModuleInitializationLevel p_level) {
        if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
        if (singleton) {
            memdelete(singleton);
            singleton = nullptr;
        }
        if (s_ctx) {
            secp256k1_context_destroy(s_ctx);
            s_ctx = nullptr;
        }
    });
    return init_obj.init();
}
}
