"""Verify Gadgetbridge's RedmiBuds SAFER+ auth against real captured frames.

Fixtures from ChristianVeneko/redmi-buds-bar Tests/BudsProtocolTests/Fixtures.swift
(captured from a real REDMI Buds 8 session).
"""
SEQ = bytes([0x11, 0x22, 0x33, 0x33, 0x22, 0x11, 0x11, 0x22,
             0x33, 0x33, 0x22, 0x11, 0x11, 0x22, 0x33, 0x33])

COEFFICIENTS = [
    [2,1,1,1,4,2,1,1,2,2,4,2,4,4,16,8],
    [2,1,1,1,4,2,1,1,1,1,2,1,2,2,8,4],
    [1,1,4,2,2,2,4,2,16,8,4,4,2,1,1,1],
    [1,1,4,2,1,1,2,1,8,4,2,2,2,1,1,1],
    [16,8,2,2,4,2,4,4,1,1,4,2,1,1,2,1],
    [8,4,1,1,2,1,2,2,1,1,4,2,1,1,2,1],
    [2,2,4,2,4,4,16,8,2,1,1,1,4,2,1,1],
    [1,1,2,1,2,2,8,4,2,1,1,1,4,2,1,1],
    [4,2,4,4,16,8,2,2,1,1,2,1,1,1,4,2],
    [2,1,2,2,8,4,1,1,1,1,2,1,1,1,4,2],
    [4,4,16,8,1,1,2,1,4,2,1,1,4,2,2,2],
    [2,2,8,4,1,1,2,1,4,2,1,1,2,1,1,1],
    [1,1,2,1,1,1,4,2,4,4,16,8,2,2,4,2],
    [1,1,2,1,1,1,4,2,2,2,8,4,1,1,2,1],
    [4,2,1,1,2,1,1,1,4,2,2,2,16,8,4,4],
    [4,2,1,1,2,1,1,1,2,1,1,1,8,4,2,2],
]

PATTERN = 0x9999
BLOCK = 16


def gen_bias_matrix():
    m = []
    for i in range(16):
        row = []
        for j in range(16):
            exp = 17 * (i + 2) + (j + 1)
            # 45^(45^exp mod 257) mod 257
            inner = pow(45, exp, 257)
            val = pow(45, inner, 257)
            row.append(0 if val == 256 else val)
        m.append(row)
    return m


def gen_exp_tab():
    t = bytearray(256)
    for i in range(256):
        if i == 128:
            t[i] = 0
        else:
            v = pow(45, i, 257)
            t[i] = 0 if v == 256 else v
    return t


def gen_log_tab():
    t = bytearray(256)
    for i in range(256):
        if i == 0:
            t[i] = 128
        else:
            v = pow(45, i, 257)
            if v != 256:
                t[v] = i
    return t


BIAS = gen_bias_matrix()
EXP = gen_exp_tab()
LOG = gen_log_tab()


def key_schedule(key_init):
    k = bytearray(key_init)
    k[15] ^= 6
    keys = [bytes(k)]
    register = list(k)
    x = 0
    for b in k:
        x ^= b
    register.append(x)
    for key_i in range(1, 17):
        for i in range(17):
            b = register[i] & 0xFF
            register[i] = ((b >> 5) | ((b << 3) & 0xFF)) & 0xFF
        ki = bytearray(16)
        for i in range(16):
            ki[i] = (register[(key_i + i) % 17] + BIAS[key_i - 1][i]) & 0xFF
        keys.append(bytes(ki))
    return keys


def encrypt(plaintext, keys):
    c = bytearray(plaintext)
    for rnd in range(8):
        if rnd == 2:
            for i in range(BLOCK):
                if (1 << i) & PATTERN:
                    c[i] ^= plaintext[i]
                else:
                    c[i] = (c[i] + plaintext[i]) & 0xFF
        for i in range(BLOCK):
            if (1 << i) & PATTERN:
                c[i] ^= keys[rnd * 2][i]
            else:
                c[i] = (c[i] + keys[rnd * 2][i]) & 0xFF
        for i in range(BLOCK):
            if (1 << i) & PATTERN:
                c[i] = EXP[c[i]]
            else:
                c[i] = LOG[c[i]]
        for i in range(BLOCK):
            if (1 << i) & PATTERN:
                c[i] = (keys[rnd * 2 + 1][i] + c[i]) & 0xFF
            else:
                c[i] = keys[rnd * 2 + 1][i] ^ c[i]
        copy = bytes(c)
        for i in range(BLOCK):
            s = 0
            for j in range(BLOCK):
                s += COEFFICIENTS[i][j] * copy[j]
            c[i] = s & 0xFF
    for i in range(BLOCK):
        if (1 << i) & PATTERN:
            c[i] = keys[16][i] ^ c[i]
        else:
            c[i] = (keys[16][i] + c[i]) & 0xFF
    return bytes(c)


def challenge_response(challenge_hex):
    ch = bytes.fromhex(challenge_hex)
    assert len(ch) == 16, len(ch)
    return encrypt(SEQ, key_schedule(ch)).hex()


if __name__ == "__main__":
    # Two independent challenge->response pairs captured from a real device.
    # Pair 1: phone sends random challenge, earbuds answer with computeResponse(challenge)
    # Pair 2: earbuds send challenge whose 16-byte body is all zeros, phone answers.
    cases = [
        ("phone challenge 67c6... -> buds answer 12953ffa...",
         "67c6697351ff4aec29cdbaabf2fbe346", "12953ffa34f0b875cd3b6850b974856c"),
        ("buds challenge (all-zero) -> phone answer bca5905b...",
         "00000000000000000000000000000000", "bca5905bc849392e7bf9fdcdc570ef77"),
    ]
    for name, ch, expected in cases:
        got = challenge_response(ch)
        print(f"{name}\n  expected={expected}\n  computed={got}\n  MATCH={got == expected}\n")
