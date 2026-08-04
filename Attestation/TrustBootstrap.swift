import Foundation

enum TrustBootstrap {
    static let tufRoot = Data(
        #"""
        {
         "signatures": [
          {
           "keyid": "e71a54d543835ba86adad9460379c7641fb8726d164ea766801a1c522aba7ea2",
           "sig": "3045022100ea2f374f409810e2db950749d9cfed09a15b6a5e25f3d5ffd0799459d7bee167022028d3acdde6dbd5034cfad222d31b41090ee21894e2c46cb8974198ab0377db44"
          },
          {
           "keyid": "22f4caec6d8e6f9555af66b3d4c3cb06a3bb23fdc7e39c916c61f462e6f52b06",
           "sig": "304402207ebb24e3237e470691d7875903a7754d0ef2ae7e7b5024a7888c9a38a52deecd02206ed5ad1c6f4fab46995843ab6b23f9420c5a4cf6ce1cb2cb2a6fc2e87e2ef3e1"
          },
          {
           "keyid": "61643838125b440b40db6942f5cb5a31c0dc04368316eb2aaa58b95904a58222",
           "sig": "304602210089d9dfd8e106cc958088a4da3c8cf7254ab6f65a9647d37ada730ef4763c5163022100d882ee744615be79861e214e1eeb9e1eddf6a1e203a201b4c5d03f5224d71d16"
          },
          {
           "keyid": "a687e5bf4fab82b0ee58d46e05c9535145a2c9afb458f43d42b45ca0fdce2a70",
           "sig": "304502210088bd4b88e83f586ce568d27d04214c4ab3fd1894178ef015303d56afa939205302205538ebab93876abb9075ad77114bff28a0d79a7cc229b534a0c5ced5526b48e7"
          },
          {
           "keyid": "183e64f37670dc13ca0d28995a3053f3740954ddce44321a41e46534cf44e632",
           "sig": "3045022100f35b07e938d4949caf82e69e86cc9db3b69b6dbc6740c1f343d06893f996fbeb022001e847d816259a96a49e42779a2350dab97b71c8ae7e26b2380c6fa7f58131b3"
          }
         ],
         "signed": {
          "_type": "root",
          "consistent_snapshot": true,
          "expires": "2026-11-20T13:58:18Z",
          "keys": {
           "0c87432c3bf09fd99189fdc32fa5eaedf4e4a5fac7bab73fa04a2e0fc64af6f5": {
            "keyid_hash_algorithms": [
             "sha256",
             "sha512"
            ],
            "keytype": "ecdsa",
            "keyval": {
             "public": "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEWRiGr5+j+3J5SsH+Ztr5nE2H2wO7\nBV+nO3s93gLca18qTOzHY1oWyAGDykMSsGTUBSt9D+An0KfKsD2mfSM42Q==\n-----END PUBLIC KEY-----\n"
            },
            "scheme": "ecdsa-sha2-nistp256",
            "x-tuf-on-ci-online-uri": "gcpkms:projects/sigstore-root-signing/locations/global/keyRings/root/cryptoKeys/timestamp/cryptoKeyVersions/1"
           },
           "183e64f37670dc13ca0d28995a3053f3740954ddce44321a41e46534cf44e632": {
            "keytype": "ecdsa",
            "keyval": {
             "public": "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMxpPOJCIZ5otG4106fGJseEQi3V9\npkMYQ4uyV9Tj1M7WHXIyLG+jkfvuG0glQ1JZbRZZBV3gAR4sojdGHISeow==\n-----END PUBLIC KEY-----\n"
            },
            "scheme": "ecdsa-sha2-nistp256",
            "x-tuf-on-ci-keyowner": "@lance"
           },
           "22f4caec6d8e6f9555af66b3d4c3cb06a3bb23fdc7e39c916c61f462e6f52b06": {
            "keyid_hash_algorithms": [
             "sha256",
             "sha512"
            ],
            "keytype": "ecdsa",
            "keyval": {
             "public": "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzBzVOmHCPojMVLSI364WiiV8NPrD\n6IgRxVliskz/v+y3JER5mcVGcONliDcWMC5J2lfHmjPNPhb4H7xm8LzfSA==\n-----END PUBLIC KEY-----\n"
            },
            "scheme": "ecdsa-sha2-nistp256",
            "x-tuf-on-ci-keyowner": "@santiagotorres"
           },
           "61643838125b440b40db6942f5cb5a31c0dc04368316eb2aaa58b95904a58222": {
            "keyid_hash_algorithms": [
             "sha256",
             "sha512"
            ],
            "keytype": "ecdsa",
            "keyval": {
             "public": "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEinikSsAQmYkNeH5eYq/CnIzLaacO\nxlSaawQDOwqKy/tCqxq5xxPSJc21K4WIhs9GyOkKfzueY3GILzcMJZ4cWw==\n-----END PUBLIC KEY-----\n"
            },
            "scheme": "ecdsa-sha2-nistp256",
            "x-tuf-on-ci-keyowner": "@bobcallaway"
           },
           "a687e5bf4fab82b0ee58d46e05c9535145a2c9afb458f43d42b45ca0fdce2a70": {
            "keyid_hash_algorithms": [
             "sha256",
             "sha512"
            ],
            "keytype": "ecdsa",
            "keyval": {
             "public": "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE0ghrh92Lw1Yr3idGV5WqCtMDB8Cx\n+D8hdC4w2ZLNIplVRoVGLskYa3gheMyOjiJ8kPi15aQ2//7P+oj7UvJPGw==\n-----END PUBLIC KEY-----\n"
            },
            "scheme": "ecdsa-sha2-nistp256",
            "x-tuf-on-ci-keyowner": "@joshuagl"
           },
           "e71a54d543835ba86adad9460379c7641fb8726d164ea766801a1c522aba7ea2": {
            "keyid_hash_algorithms": [
             "sha256",
             "sha512"
            ],
            "keytype": "ecdsa",
            "keyval": {
             "public": "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEEXsz3SZXFb8jMV42j6pJlyjbjR8K\nN3Bwocexq6LMIb5qsWKOQvLN16NUefLc4HswOoumRsVVaajSpQS6fobkRw==\n-----END PUBLIC KEY-----\n"
            },
            "scheme": "ecdsa-sha2-nistp256",
            "x-tuf-on-ci-keyowner": "@mnm678"
           }
          },
          "roles": {
           "root": {
            "keyids": [
             "e71a54d543835ba86adad9460379c7641fb8726d164ea766801a1c522aba7ea2",
             "22f4caec6d8e6f9555af66b3d4c3cb06a3bb23fdc7e39c916c61f462e6f52b06",
             "61643838125b440b40db6942f5cb5a31c0dc04368316eb2aaa58b95904a58222",
             "a687e5bf4fab82b0ee58d46e05c9535145a2c9afb458f43d42b45ca0fdce2a70",
             "183e64f37670dc13ca0d28995a3053f3740954ddce44321a41e46534cf44e632"
            ],
            "threshold": 3
           },
           "snapshot": {
            "keyids": [
             "0c87432c3bf09fd99189fdc32fa5eaedf4e4a5fac7bab73fa04a2e0fc64af6f5"
            ],
            "threshold": 1,
            "x-tuf-on-ci-expiry-period": 3650,
            "x-tuf-on-ci-signing-period": 365
           },
           "targets": {
            "keyids": [
             "e71a54d543835ba86adad9460379c7641fb8726d164ea766801a1c522aba7ea2",
             "22f4caec6d8e6f9555af66b3d4c3cb06a3bb23fdc7e39c916c61f462e6f52b06",
             "61643838125b440b40db6942f5cb5a31c0dc04368316eb2aaa58b95904a58222",
             "a687e5bf4fab82b0ee58d46e05c9535145a2c9afb458f43d42b45ca0fdce2a70",
             "183e64f37670dc13ca0d28995a3053f3740954ddce44321a41e46534cf44e632"
            ],
            "threshold": 3
           },
           "timestamp": {
            "keyids": [
             "0c87432c3bf09fd99189fdc32fa5eaedf4e4a5fac7bab73fa04a2e0fc64af6f5"
            ],
            "threshold": 1,
            "x-tuf-on-ci-expiry-period": 7,
            "x-tuf-on-ci-signing-period": 6
           }
          },
          "spec_version": "1.0",
          "version": 15,
          "x-tuf-on-ci-expiry-period": 197,
          "x-tuf-on-ci-signing-period": 46
         }
        }
        """#.utf8
    )

    static let trustedRoot = Data(
        #"""
        {
          "mediaType": "application/vnd.dev.sigstore.trustedroot+json;version=0.1",
          "tlogs": [
            {
              "baseUrl": "https://rekor.sigstore.dev",
              "hashAlgorithm": "SHA2_256",
              "publicKey": {
                "rawBytes": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE2G2Y+2tabdTV5BcGiBIx0a9fAFwrkBbmLSGtks4L3qX6yYY0zufBnhC8Ur/iy55GhWP/9A/bY2LhC30M9+RYtw==",
                "keyDetails": "PKIX_ECDSA_P256_SHA_256",
                "validFor": {
                  "start": "2021-01-12T11:53:27Z"
                }
              },
              "logId": {
                "keyId": "wNI9atQGlz+VWfO6LRygH4QUfY/8W4RFwiT5i5WRgB0="
              }
            },
            {
              "baseUrl": "https://log2025-1.rekor.sigstore.dev",
              "hashAlgorithm": "SHA2_256",
              "publicKey": {
                "rawBytes": "MCowBQYDK2VwAyEAt8rlp1knGwjfbcXAYPYAkn0XiLz1x8O4t0YkEhie244=",
                "keyDetails": "PKIX_ED25519",
                "validFor": {
                  "start": "2025-09-23T00:00:00Z"
                }
              },
              "logId": {
                "keyId": "zxGZFVvd0FEmjR8WrFwMdcAJ9vtaY/QXf44Y1wUeP6A="
              }
            }
          ],
          "certificateAuthorities": [
            {
              "subject": {
                "organization": "sigstore.dev",
                "commonName": "sigstore"
              },
              "uri": "https://fulcio.sigstore.dev",
              "certChain": {
                "certificates": [
                  {
                    "rawBytes": "MIIB+DCCAX6gAwIBAgITNVkDZoCiofPDsy7dfm6geLbuhzAKBggqhkjOPQQDAzAqMRUwEwYDVQQKEwxzaWdzdG9yZS5kZXYxETAPBgNVBAMTCHNpZ3N0b3JlMB4XDTIxMDMwNzAzMjAyOVoXDTMxMDIyMzAzMjAyOVowKjEVMBMGA1UEChMMc2lnc3RvcmUuZGV2MREwDwYDVQQDEwhzaWdzdG9yZTB2MBAGByqGSM49AgEGBSuBBAAiA2IABLSyA7Ii5k+pNO8ZEWY0ylemWDowOkNa3kL+GZE5Z5GWehL9/A9bRNA3RbrsZ5i0JcastaRL7Sp5fp/jD5dxqc/UdTVnlvS16an+2Yfswe/QuLolRUCrcOE2+2iA5+tzd6NmMGQwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQEwHQYDVR0OBBYEFMjFHQBBmiQpMlEk6w2uSu1KBtPsMB8GA1UdIwQYMBaAFMjFHQBBmiQpMlEk6w2uSu1KBtPsMAoGCCqGSM49BAMDA2gAMGUCMH8liWJfMui6vXXBhjDgY4MwslmN/TJxVe/83WrFomwmNf056y1X48F9c4m3a3ozXAIxAKjRay5/aj/jsKKGIkmQatjI8uupHr/+CxFvaJWmpYqNkLDGRU+9orzh5hI2RrcuaQ=="
                  }
                ]
              },
              "validFor": {
                "start": "2021-03-07T03:20:29Z",
                "end": "2022-12-31T23:59:59.999Z"
              }
            },
            {
              "subject": {
                "organization": "sigstore.dev",
                "commonName": "sigstore"
              },
              "uri": "https://fulcio.sigstore.dev",
              "certChain": {
                "certificates": [
                  {
                    "rawBytes": "MIICGjCCAaGgAwIBAgIUALnViVfnU0brJasmRkHrn/UnfaQwCgYIKoZIzj0EAwMwKjEVMBMGA1UEChMMc2lnc3RvcmUuZGV2MREwDwYDVQQDEwhzaWdzdG9yZTAeFw0yMjA0MTMyMDA2MTVaFw0zMTEwMDUxMzU2NThaMDcxFTATBgNVBAoTDHNpZ3N0b3JlLmRldjEeMBwGA1UEAxMVc2lnc3RvcmUtaW50ZXJtZWRpYXRlMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE8RVS/ysH+NOvuDZyPIZtilgUF9NlarYpAd9HP1vBBH1U5CV77LSS7s0ZiH4nE7Hv7ptS6LvvR/STk798LVgMzLlJ4HeIfF3tHSaexLcYpSASr1kS0N/RgBJz/9jWCiXno3sweTAOBgNVHQ8BAf8EBAMCAQYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU39Ppz1YkEZb5qNjpKFWixi4YZD8wHwYDVR0jBBgwFoAUWMAeX5FFpWapesyQoZMi0CrFxfowCgYIKoZIzj0EAwMDZwAwZAIwPCsQK4DYiZYDPIaDi5HFKnfxXx6ASSVmERfsynYBiX2X6SJRnZU84/9DZdnFvvxmAjBOt6QpBlc4J/0DxvkTCqpclvziL6BCCPnjdlIB3Pu3BxsPmygUY7Ii2zbdCdliiow="
                  },
                  {
                    "rawBytes": "MIIB9zCCAXygAwIBAgIUALZNAPFdxHPwjeDloDwyYChAO/4wCgYIKoZIzj0EAwMwKjEVMBMGA1UEChMMc2lnc3RvcmUuZGV2MREwDwYDVQQDEwhzaWdzdG9yZTAeFw0yMTEwMDcxMzU2NTlaFw0zMTEwMDUxMzU2NThaMCoxFTATBgNVBAoTDHNpZ3N0b3JlLmRldjERMA8GA1UEAxMIc2lnc3RvcmUwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAT7XeFT4rb3PQGwS4IajtLk3/OlnpgangaBclYpsYBr5i+4ynB07ceb3LP0OIOZdxexX69c5iVuyJRQ+Hz05yi+UF3uBWAlHpiS5sh0+H2GHE7SXrk1EC5m1Tr19L9gg92jYzBhMA4GA1UdDwEB/wQEAwIBBjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBRYwB5fkUWlZql6zJChkyLQKsXF+jAfBgNVHSMEGDAWgBRYwB5fkUWlZql6zJChkyLQKsXF+jAKBggqhkjOPQQDAwNpADBmAjEAj1nHeXZp+13NWBNa+EDsDP8G1WWg1tCMWP/WHPqpaVo0jhsweNFZgSs0eE7wYI4qAjEA2WB9ot98sIkoF3vZYdd3/VtWB5b9TNMea7Ix/stJ5TfcLLeABLE4BNJOsQ4vnBHJ"
                  }
                ]
              },
              "validFor": {
                "start": "2022-04-13T20:06:15Z"
              }
            }
          ],
          "ctlogs": [
            {
              "baseUrl": "https://ctfe.sigstore.dev/test",
              "hashAlgorithm": "SHA2_256",
              "publicKey": {
                "rawBytes": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEbfwR+RJudXscgRBRpKX1XFDy3PyudDxz/SfnRi1fT8ekpfBd2O1uoz7jr3Z8nKzxA69EUQ+eFCFI3zeubPWU7w==",
                "keyDetails": "PKIX_ECDSA_P256_SHA_256",
                "validFor": {
                  "start": "2021-03-14T00:00:00Z",
                  "end": "2022-10-31T23:59:59.999Z"
                }
              },
              "logId": {
                "keyId": "CGCS8ChS/2hF0dFrJ4ScRWcYrBY9wzjSbea8IgY2b3I="
              }
            },
            {
              "baseUrl": "https://ctfe.sigstore.dev/2022",
              "hashAlgorithm": "SHA2_256",
              "publicKey": {
                "rawBytes": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEiPSlFi0CmFTfEjCUqF9HuCEcYXNKAaYalIJmBZ8yyezPjTqhxrKBpMnaocVtLJBI1eM3uXnQzQGAJdJ4gs9Fyw==",
                "keyDetails": "PKIX_ECDSA_P256_SHA_256",
                "validFor": {
                  "start": "2022-10-20T00:00:00Z"
                }
              },
              "logId": {
                "keyId": "3T0wasbHETJjGR4cmWc3AqJKXrjePK3/h4pygC8p7o4="
              }
            }
          ],
          "timestampAuthorities": [
            {
              "subject": {
                "organization": "sigstore.dev",
                "commonName": "sigstore-tsa-selfsigned"
              },
              "uri": "https://timestamp.sigstore.dev/api/v1/timestamp",
              "certChain": {
                "certificates": [
                  {
                    "rawBytes": "MIICEDCCAZagAwIBAgIUOhNULwyQYe68wUMvy4qOiyojiwwwCgYIKoZIzj0EAwMwOTEVMBMGA1UEChMMc2lnc3RvcmUuZGV2MSAwHgYDVQQDExdzaWdzdG9yZS10c2Etc2VsZnNpZ25lZDAeFw0yNTA0MDgwNjU5NDNaFw0zNTA0MDYwNjU5NDNaMC4xFTATBgNVBAoTDHNpZ3N0b3JlLmRldjEVMBMGA1UEAxMMc2lnc3RvcmUtdHNhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE4ra2Z8hKNig2T9kFjCAToGG30jky+WQv3BzL+mKvh1SKNR/UwuwsfNCg4sryoYAd8E6isovVA3M4aoNdm9QDi50Z8nTEyvqgfDPtTIwXItfiW/AFf1V7uwkbkAoj0xxco2owaDAOBgNVHQ8BAf8EBAMCB4AwHQYDVR0OBBYEFIn9eUOHz9BlRsMCRscsc1t9tOsDMB8GA1UdIwQYMBaAFJjsAe9/u1H/1JUeb4qImFMHic6/MBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMAoGCCqGSM49BAMDA2gAMGUCMDtpsV/6KaO0qyF/UMsX2aSUXKQFdoGTptQGc0ftq1csulHPGG6dsmyMNd3JB+G3EQIxAOajvBcjpJmKb4Nv+2Taoj8Uc5+b6ih6FXCCKraSqupe07zqswMcXJTe1cExvHvvlw=="
                  },
                  {
                    "rawBytes": "MIIB9zCCAXygAwIBAgIUV7f0GLDOoEzIh8LXSW80OJiUp14wCgYIKoZIzj0EAwMwOTEVMBMGA1UEChMMc2lnc3RvcmUuZGV2MSAwHgYDVQQDExdzaWdzdG9yZS10c2Etc2VsZnNpZ25lZDAeFw0yNTA0MDgwNjU5NDNaFw0zNTA0MDYwNjU5NDNaMDkxFTATBgNVBAoTDHNpZ3N0b3JlLmRldjEgMB4GA1UEAxMXc2lnc3RvcmUtdHNhLXNlbGZzaWduZWQwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAQUQNtfRT/ou3YATa6wB/kKTe70cfJwyRIBovMnt8RcJph/COE82uyS6FmppLLL1VBPGcPfpQPYJNXzWwi8icwhKQ6W/Qe2h3oebBb2FHpwNJDqo+TMaC/tdfkv/ElJB72jRTBDMA4GA1UdDwEB/wQEAwIBBjASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBSY7AHvf7tR/9SVHm+KiJhTB4nOvzAKBggqhkjOPQQDAwNpADBmAjEAwGEGrfGZR1cen1R8/DTVMI943LssZmJRtDp/i7SfGHmGRP6gRbuj9vOK3b67Z0QQAjEAuT2H673LQEaHTcyQSZrkp4mX7WwkmF+sVbkYY5mXN+RMH13KUEHHOqASaemYWK/E"
                  }
                ]
              },
              "validFor": {
                "start": "2025-07-04T00:00:00Z"
              }
            }
          ]
        }
        """#.utf8
    )
}
