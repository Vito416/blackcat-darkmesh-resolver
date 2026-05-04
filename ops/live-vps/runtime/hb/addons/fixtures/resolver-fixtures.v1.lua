return {
  {
    name = "baseline_off_unmapped_allow",
    steps = {
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "unknown-example.fun",
          ["Request-Id"] = "rid-baseline-1",
        },
        expect = {
          ["status"] = "OK",
          ["payload.decision"] = "allow",
          ["payload.reasonCode"] = "ALLOW_HOST_UNMAPPED_MODE_OFF",
        },
      },
    },
  },
  {
    name = "soft_unmapped_fail_closed_denies",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "soft",
          ["Fail-Open"] = "false",
        },
        expect = {
          ["status"] = "OK",
          ["payload.policyMode"] = "soft",
          ["payload.failOpen"] = false,
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "unknown-example.fun",
          ["Request-Id"] = "rid-soft-1",
        },
        expect = {
          ["status"] = "OK",
          ["payload.decision"] = "deny",
          ["payload.reasonCode"] = "DENY_READY_HOST_UNMAPPED",
        },
      },
    },
  },
  {
    name = "apply_bundle_requires_process_mapping",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
          },
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "INVALID_INPUT",
          ["message"] = "missing_process_mapping:hostPolicies.alpha.example",
        },
      },
    },
  },
  {
    name = "unchecked_proof_denied_in_soft_mode",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "soft",
          ["Fail-Open"] = "false",
          Bundle = {
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
                moduleId = "TrNj8CSFaevoYSAsnxuQ97SkdDuPvpkgxR-L6i3QCzY",
                scheduler = "_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM",
                routePrefix = "/",
              },
            },
            dnsProofState = {
              ["alpha.example"] = {
                state = "unchecked",
                checkedAt = "2026-04-24T08:00:00Z",
                source = "fixture",
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "alpha.example",
          ["Request-Id"] = "rid-proof-1",
        },
        expect = {
          ["status"] = "OK",
          ["payload.decision"] = "deny",
          ["payload.reasonCode"] = "DENY_READY_DNS_PROOF_UNCHECKED",
        },
      },
    },
  },
  {
    name = "idempotency_key_includes_path_method",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
                moduleId = "TrNj8CSFaevoYSAsnxuQ97SkdDuPvpkgxR-L6i3QCzY",
                scheduler = "_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM",
                routePrefix = "/",
              },
            },
            dnsProofState = {
              ["alpha.example"] = {
                state = "valid",
                checkedAt = "2026-04-24T08:00:00Z",
                validUntil = "2026-04-24T09:00:00Z",
                source = "fixture",
              },
            },
            routePolicies = {
              ["alpha.example"] = {
                rules = {
                  {
                    pathPrefix = "/api",
                    methods = { "GET", "HEAD" },
                    actionHint = "read",
                  },
                },
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "ResolveRouteForHost",
          Host = "alpha.example",
          Path = "/api/items",
          Method = "GET",
          ["Request-Id"] = "rid-route-shared",
        },
        expect = {
          ["status"] = "OK",
          ["payload.routeHint.actionHint"] = "read",
        },
      },
      {
        msg = {
          Action = "ResolveRouteForHost",
          Host = "alpha.example",
          Path = "/checkout",
          Method = "POST",
          ["Request-Id"] = "rid-route-shared",
        },
        expect = {
          ["status"] = "OK",
          ["payload.routeHint.actionHint"] = "write",
        },
      },
    },
  },
  {
    name = "missing_request_id_no_replay_collision",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
                moduleId = "TrNj8CSFaevoYSAsnxuQ97SkdDuPvpkgxR-L6i3QCzY",
                scheduler = "_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM",
                routePrefix = "/",
              },
            },
            dnsProofState = {
              ["alpha.example"] = {
                state = "valid",
                checkedAt = "2026-04-24T08:00:00Z",
                validUntil = "2026-04-24T09:00:00Z",
                source = "fixture",
              },
            },
            routePolicies = {
              ["alpha.example"] = {
                rules = {
                  {
                    pathPrefix = "/api",
                    methods = { "GET", "HEAD" },
                    actionHint = "read",
                  },
                },
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "ResolveRouteForHost",
          Host = "alpha.example",
          Path = "/checkout",
          Method = "POST",
        },
        expect = {
          ["status"] = "OK",
          ["payload.routeHint.actionHint"] = "write",
        },
      },
      {
        msg = {
          Action = "ResolveRouteForHost",
          Host = "alpha.example",
          Path = "/api/items",
          Method = "GET",
        },
        expect = {
          ["status"] = "OK",
          ["payload.routeHint.actionHint"] = "read",
        },
      },
    },
  },
  {
    name = "cache_hint_range_validation",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          ["Cache-Hints"] = {
            negativeTtlSec = 0,
          },
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "INVALID_INPUT",
          ["message"] = "invalid_range:negativeTtlSec",
        },
      },
    },
  },
  {
    name = "cache_hint_relation_validation",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          ["Cache-Hints"] = {
            staleWhileRevalidateSec = 120,
            hardMaxStaleSec = 60,
          },
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "INVALID_INPUT",
          ["message"] = "invalid_relation:hardMaxStaleSec",
        },
      },
    },
  },
  {
    name = "dns_refresh_due_list_and_apply_result",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "ListHostsDueForDnsRefresh",
          ["Actor-Role"] = "admin",
          ["Now-Epoch"] = 1700000000,
          Limit = 10,
        },
        expect = {
          ["status"] = "OK",
          ["payload.counts.returned"] = 1,
          ["payload.dueHosts.1.host"] = "alpha.example",
        },
      },
      {
        msg = {
          Action = "ApplyDnsRefreshResult",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          ["Dns-Proof-State"] = "valid",
          ["Checked-At"] = "2026-04-24T10:00:00Z",
          ["Next-Check-At"] = "2099-01-01T00:00:00Z",
          ["Dns-Proof-Valid-Until"] = "2099-01-01T00:00:00Z",
          ["Dns-Proof-Source"] = "fixture",
          ["Site-Id"] = "site-jdwt",
          ["Process-Id"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
        },
        expect = {
          ["status"] = "OK",
          ["payload.dnsProofState.state"] = "valid",
          ["payload.refreshMeta.nextCheckAt"] = "2099-01-01T00:00:00Z",
          ["payload.cacheInvalidation.scope"] = "host",
        },
      },
      {
        msg = {
          Action = "ListHostsDueForDnsRefresh",
          ["Actor-Role"] = "admin",
          ["Now-Epoch"] = 1700000000,
          Limit = 10,
        },
        expect = {
          ["status"] = "OK",
          ["payload.counts.returned"] = 0,
        },
      },
    },
  },
  {
    name = "dns_refresh_invalid_proof_state_rejected",
    steps = {
      {
        msg = {
          Action = "ApplyDnsRefreshResult",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          ["Dns-Proof-State"] = "bogus",
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "INVALID_INPUT",
          ["message"] = "missing_field:Dns-Proof-State-or-Error",
        },
      },
    },
  },
  {
    name = "on_access_refresh_requests_use_stock_paths",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            autoDns = {
              enabled = true,
              refreshOnStale = true,
              staleRefreshMinIntervalSec = 3600,
              relayPath = "/~relay@1.0",
              cachePath = "/~cache@1.0",
              cronPath = "/~cron@1.0",
            },
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
              },
            },
            dnsProofState = {
              ["alpha.example"] = {
                state = "expired",
                checkedAt = "2026-04-24T08:00:00Z",
                validUntil = "2026-04-24T08:10:00Z",
                source = "fixture",
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
          ["payload.autoDns.enabled"] = true,
          ["payload.autoDns.paths.relayPath"] = "/~relay@1.0",
          ["payload.autoDns.paths.cachePath"] = "/~cache@1.0",
          ["payload.autoDns.paths.cronPath"] = "/~cron@1.0",
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "alpha.example",
          ["Request-Id"] = "rid-refresh-first",
        },
        expect = {
          ["status"] = "OK",
          ["payload.cache.cacheState"] = "miss",
          ["payload.refresh.enabled"] = true,
          ["payload.refresh.requested"] = true,
          ["payload.refresh.reason"] = "proof_expired",
          ["payload.refresh.paths.relayPath"] = "/~relay@1.0",
          ["payload.refresh.paths.cachePath"] = "/~cache@1.0",
          ["payload.refresh.paths.cronPath"] = "/~cron@1.0",
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "alpha.example",
          ["Request-Id"] = "rid-refresh-second",
        },
        expect = {
          ["status"] = "OK",
          ["payload.cache.cacheState"] = "hit",
          ["payload.refresh.enabled"] = true,
          ["payload.refresh.requested"] = false,
          ["payload.refresh.reason"] = "proof_expired",
        },
      },
    },
  },
  {
    name = "force_dns_refresh_host_sets_due_now",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            autoDns = {
              enabled = true,
            },
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "ForceDnsRefreshHost",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          Reason = "fixture_force",
        },
        expect = {
          ["status"] = "OK",
          ["payload.forced"] = true,
          ["payload.host"] = "alpha.example",
          ["payload.reason"] = "fixture_force",
          ["payload.autoDns.paths.relayPath"] = "/~relay@1.0",
          ["payload.autoDns.paths.cachePath"] = "/~cache@1.0",
          ["payload.autoDns.paths.cronPath"] = "/~cron@1.0",
        },
      },
      {
        msg = {
          Action = "ListHostsDueForDnsRefresh",
          ["Actor-Role"] = "admin",
          ["Now-Epoch"] = 4102444799,
          Limit = 10,
        },
        expect = {
          ["status"] = "OK",
          ["payload.counts.returned"] = 1,
          ["payload.dueHosts.1.host"] = "alpha.example",
          ["payload.dueHosts.1.lastRequestedReason"] = "fixture_force",
        },
      },
    },
  },
  {
    name = "run_auto_dns_tick_hb_native_plan",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            autoDns = {
              enabled = true,
              staleRefreshMinIntervalSec = 3600,
              relayPath = "/~relay@1.0",
              cachePath = "/~cache@1.0",
              cronPath = "/~cron@1.0",
              dohEndpoint = "https://cloudflare-dns.com/dns-query",
              arweaveBase = "https://arweave.net",
            },
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "RunAutoDnsTick",
          ["Actor-Role"] = "admin",
          ["Now-Epoch"] = 4102444799,
          Limit = 10,
        },
        expect = {
          ["status"] = "OK",
          ["payload.autoDns.enabled"] = true,
          ["payload.relayPlan.mode"] = "hb_native",
          ["payload.relayPlan.applyAction"] = "ApplyDnsRefreshResult",
          ["payload.autoDns.paths.relayPath"] = "/~relay@1.0",
          ["payload.autoDns.paths.cachePath"] = "/~cache@1.0",
          ["payload.autoDns.paths.cronPath"] = "/~cron@1.0",
          ["payload.autoDns.endpoints.dohEndpoint"] = "https://cloudflare-dns.com/dns-query",
          ["payload.autoDns.endpoints.arweaveBase"] = "https://arweave.net",
          ["payload.counts.returned"] = 1,
          ["payload.dueHosts.1.host"] = "alpha.example",
          ["payload.dueHosts.1.queued"] = true,
        },
      },
      {
        msg = {
          Action = "RunAutoDnsTick",
          ["Actor-Role"] = "admin",
          ["Now-Epoch"] = 4102444799,
          Limit = 10,
        },
        expect = {
          ["status"] = "OK",
          ["payload.counts.returned"] = 1,
          ["payload.dueHosts.1.queued"] = false,
        },
      },
    },
  },
  {
    name = "challenge_bound_refresh_and_seq_guard",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            autoDns = {
              enabled = true,
              requireChallenge = true,
              challengeTtlSec = 300,
            },
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
          ["payload.autoDns.requireChallenge"] = true,
          ["payload.autoDns.challengeTtlSec"] = 300,
        },
      },
      {
        msg = {
          Action = "IssueDnsRefreshChallenge",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          Reason = "fixture_issue",
          ["Challenge-Ref"] = "fixture-challenge-1",
          ["Challenge-Ttl-Sec"] = 120,
        },
        expect = {
          ["status"] = "OK",
          ["payload.challenge.challengeRef"] = "fixture-challenge-1",
          ["payload.challenge.required"] = true,
          ["payload.challenge.challengeTtlSec"] = 120,
        },
      },
      {
        msg = {
          Action = "ApplyDnsRefreshResult",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          ["Dns-Proof-State"] = "valid",
          ["Dns-Proof-Seq"] = 5,
          ["Challenge-Ref"] = "fixture-challenge-x",
          ["Checked-At"] = "2026-04-24T10:00:00Z",
          ["Dns-Proof-Valid-Until"] = "2026-04-24T11:00:00Z",
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "INVALID_INPUT",
          ["message"] = "challenge_mismatch",
        },
      },
      {
        msg = {
          Action = "ApplyDnsRefreshResult",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          ["Dns-Proof-State"] = "valid",
          ["Dns-Proof-Seq"] = 5,
          ["Challenge-Ref"] = "fixture-challenge-1",
          ["Checked-At"] = "2026-04-24T10:00:00Z",
          ["Dns-Proof-Valid-Until"] = "2026-04-24T11:00:00Z",
          ["Site-Id"] = "site-jdwt",
          ["Process-Id"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
        },
        expect = {
          ["status"] = "OK",
          ["payload.dnsProofState.sequence"] = 5,
        },
      },
      {
        msg = {
          Action = "IssueDnsRefreshChallenge",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          Reason = "fixture_issue_2",
          ["Challenge-Ref"] = "fixture-challenge-2",
          ["Challenge-Ttl-Sec"] = 120,
        },
        expect = {
          ["status"] = "OK",
          ["payload.challenge.challengeRef"] = "fixture-challenge-2",
        },
      },
      {
        msg = {
          Action = "ApplyDnsRefreshResult",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          ["Dns-Proof-State"] = "valid",
          ["Dns-Proof-Seq"] = 4,
          ["Challenge-Ref"] = "fixture-challenge-2",
          ["Checked-At"] = "2026-04-24T10:05:00Z",
          ["Dns-Proof-Valid-Until"] = "2026-04-24T11:05:00Z",
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "INVALID_INPUT",
          ["message"] = "stale_sequence:Dns-Proof-Seq",
        },
      },
    },
  },
  {
    name = "run_auto_dns_tick_includes_challenge_contract",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            autoDns = {
              enabled = true,
              requireChallenge = true,
              challengeTtlSec = 180,
            },
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "RunAutoDnsTick",
          ["Actor-Role"] = "admin",
          ["Now-Epoch"] = 4102444799,
          Limit = 10,
        },
        expect = {
          ["status"] = "OK",
          ["payload.autoDns.requireChallenge"] = true,
          ["payload.autoDns.challengeTtlSec"] = 180,
          ["payload.relayPlan.challenge.required"] = true,
          ["payload.relayPlan.challenge.issueAction"] = "IssueDnsRefreshChallenge",
          ["payload.relayPlan.challenge.ttlSec"] = 180,
          ["payload.counts.returned"] = 1,
          ["payload.dueHosts.1.queued"] = true,
        },
      },
    },
  },
  {
    name = "state_and_cache_admin_actions_covered",
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-jdwt",
              },
            },
            sitePolicies = {
              ["site-jdwt"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "alpha.example",
          ["Request-Id"] = "rid-state-cover",
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "GetResolverState",
        },
        expect = {
          ["status"] = "OK",
          ["payload.counts.hostPolicies"] = 1,
        },
      },
      {
        msg = {
          Action = "GetResolverCacheStats",
        },
        expect = {
          ["status"] = "OK",
          ["payload.counts.entriesTotal"] = 1,
        },
      },
      {
        msg = {
          Action = "GetDnsRefreshState",
        },
        expect = {
          ["status"] = "OK",
          ["payload.counts.trackedHosts"] = 1,
        },
      },
      {
        msg = {
          Action = "InvalidateResolverCache",
          ["Actor-Role"] = "admin",
          Scope = "host",
          Host = "alpha.example",
        },
        expect = {
          ["status"] = "OK",
          ["payload.scope"] = "host",
          ["payload.remainingEntries"] = 0,
        },
      },
    },
  },
  {
    name = "admission_rules_deny_then_remove",
    steps = {
      {
        msg = {
          Action = "SetAdmissionRule",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          Rule = "deny",
          Reason = "manual_block",
        },
        expect = {
          ["status"] = "OK",
          ["payload.rule"] = "deny",
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "alpha.example",
          ["Request-Id"] = "rid-admission-deny",
        },
        expect = {
          ["status"] = "OK",
          ["payload.decision"] = "deny",
          ["payload.reasonCode"] = "manual_block",
        },
      },
      {
        msg = {
          Action = "GetAdmissionState",
        },
        expect = {
          ["status"] = "OK",
          ["payload.admission.denyCount"] = 1,
        },
      },
      {
        msg = {
          Action = "RemoveAdmissionRule",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          Rule = "deny",
        },
        expect = {
          ["status"] = "OK",
          ["payload.admission.denyCount"] = 0,
        },
      },
    },
  },
  {
    name = "refresh_mutations_role_gated",
    steps = {
      {
        msg = {
          Action = "ApplyDnsRefreshResult",
          ["Actor-Role"] = "viewer",
          Host = "alpha.example",
          ["Dns-Proof-State"] = "valid",
          ["Checked-At"] = "2026-04-24T10:00:00Z",
          ["Site-Id"] = "site-alpha",
          ["Process-Id"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "FORBIDDEN",
          ["message"] = "forbidden_actor_role",
        },
      },
      {
        msg = {
          Action = "ForceDnsRefreshHost",
          ["Actor-Role"] = "viewer",
          Host = "alpha.example",
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "FORBIDDEN",
          ["message"] = "forbidden_actor_role",
        },
      },
      {
        msg = {
          Action = "IssueDnsRefreshChallenge",
          ["Actor-Role"] = "viewer",
          Host = "alpha.example",
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "FORBIDDEN",
          ["message"] = "forbidden_actor_role",
        },
      },
      {
        msg = {
          Action = "ApplyHostPolicyFromProof",
          ["Actor-Role"] = "viewer",
          Host = "alpha.example",
          ["Process-Id"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "FORBIDDEN",
          ["message"] = "forbidden_actor_role",
        },
      },
    },
  },
  {
    name = "public_read_refresh_queue_read_only_by_default",
    env = {
      RESOLVER_ALLOW_PUBLIC_READ_REFRESH_QUEUE = "0",
    },
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            autoDns = {
              enabled = true,
              refreshOnStale = true,
              staleRefreshMinIntervalSec = 0,
            },
            hostPolicies = {
              ["alpha.example"] = {
                siteId = "site-alpha",
              },
            },
            sitePolicies = {
              ["site-alpha"] = {
                processId = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
              },
            },
            dnsProofState = {
              ["alpha.example"] = {
                state = "expired",
                checkedAt = "2026-04-24T08:00:00Z",
                validUntil = "2026-04-24T08:10:00Z",
                source = "fixture",
              },
            },
          },
        },
        expect = {
          ["status"] = "OK",
          ["payload.autoDns.enabled"] = true,
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "alpha.example",
          ["Request-Id"] = "rid-readonly-refresh",
        },
        expect = {
          ["status"] = "OK",
          ["payload.refresh.enabled"] = true,
          ["payload.refresh.requested"] = false,
          ["payload.refresh.source"] = "read_only",
          ["payload.refresh.reason"] = "proof_expired",
        },
      },
      {
        msg = {
          Action = "GetDnsRefreshState",
        },
        expect = {
          ["status"] = "OK",
          ["payload.counts.withPendingRequest"] = 0,
        },
      },
    },
  },
  {
    name = "refresh_meta_cap_prunes_overflow",
    env = {
      RESOLVER_REFRESH_META_MAX_HOSTS = "2",
      RESOLVER_REFRESH_META_STALE_TTL_SEC = "86400",
      RESOLVER_ALLOW_PUBLIC_READ_REFRESH_QUEUE = "1",
    },
    steps = {
      {
        msg = {
          Action = "ApplyPolicyBundle",
          ["Actor-Role"] = "admin",
          ["Policy-Mode"] = "off",
          ["Fail-Open"] = "true",
          Bundle = {
            autoDns = {
              enabled = true,
              refreshOnStale = true,
              staleRefreshMinIntervalSec = 0,
            },
          },
        },
        expect = {
          ["status"] = "OK",
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "a.example",
          ["Request-Id"] = "rid-cap-a",
        },
        expect = {
          ["status"] = "OK",
          ["payload.refresh.requested"] = true,
          ["payload.refresh.reason"] = "host_unmapped",
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "b.example",
          ["Request-Id"] = "rid-cap-b",
        },
        expect = {
          ["status"] = "OK",
          ["payload.refresh.requested"] = true,
          ["payload.refresh.reason"] = "host_unmapped",
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "c.example",
          ["Request-Id"] = "rid-cap-c",
        },
        expect = {
          ["status"] = "OK",
          ["payload.refresh.requested"] = true,
          ["payload.refresh.reason"] = "host_unmapped",
        },
      },
      {
        msg = {
          Action = "GetDnsRefreshState",
        },
        expect = {
          ["status"] = "OK",
          ["payload.counts.trackedHosts"] = 2,
          ["payload.counts.withPendingRequest"] = 2,
        },
      },
    },
  },
  {
    name = "direct_host_policy_apply_disabled_by_default",
    env = {
      RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY = "0",
    },
    steps = {
      {
        msg = {
          Action = "ApplyHostPolicyFromProof",
          ["Actor-Role"] = "admin",
          Host = "alpha.example",
          ["Site-Id"] = "site-alpha",
          ["Process-Id"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
        },
        expect = {
          ["status"] = "ERROR",
          ["code"] = "FORBIDDEN",
          ["message"] = "direct_host_policy_apply_disabled",
        },
      },
    },
  },
  {
    name = "apply_host_policy_from_proof_sets_mapping",
    env = {
      RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY = "1",
    },
    steps = {
      {
        msg = {
          Action = "ApplyHostPolicyFromProof",
          Host = "alpha.example",
          ["Site-Id"] = "site-alpha",
          ["Process-Id"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
          ["Module-Id"] = "TrNj8CSFaevoYSAsnxuQ97SkdDuPvpkgxR-L6i3QCzY",
          ["Scheduler-Id"] = "_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM",
          ["Route-Prefix"] = "/",
          Status = "active",
        },
        expect = {
          ["status"] = "OK",
          ["payload.applied"] = true,
          ["payload.hostPolicy.siteId"] = "site-alpha",
          ["payload.hostPolicy.processId"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "alpha.example",
          ["Request-Id"] = "rid-proof-map",
        },
        expect = {
          ["status"] = "OK",
          ["payload.decision"] = "allow",
          ["payload.process.processId"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
          ["payload.reasonCode"] = "ALLOW_DNS_PROOF_UNCHECKED_MODE_OFF",
        },
      },
    },
  },
  {
    name = "www_alias_falls_back_to_apex_mapping",
    env = {
      RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY = "1",
    },
    steps = {
      {
        msg = {
          Action = "ApplyHostPolicyFromProof",
          Host = "jdwt.fun",
          ["Site-Id"] = "site-jdwt",
          ["Process-Id"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
          ["Module-Id"] = "TrNj8CSFaevoYSAsnxuQ97SkdDuPvpkgxR-L6i3QCzY",
          ["Scheduler-Id"] = "_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM",
          ["Route-Prefix"] = "/",
          Status = "active",
        },
        expect = {
          ["status"] = "OK",
          ["payload.applied"] = true,
        },
      },
      {
        msg = {
          Action = "ResolveHostForNode",
          Host = "www.jdwt.fun",
          ["Request-Id"] = "rid-www-host",
        },
        expect = {
          ["status"] = "OK",
          ["payload.decision"] = "allow",
          ["payload.process.processId"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
          ["payload.site.siteId"] = "site-jdwt",
          ["payload.host"] = "www.jdwt.fun",
        },
      },
      {
        msg = {
          Action = "ResolveRouteForHost",
          Host = "www.jdwt.fun",
          Path = "/",
          Method = "GET",
          ["Request-Id"] = "rid-www-route",
        },
        expect = {
          ["status"] = "OK",
          ["payload.decision"] = "allow",
          ["payload.process.processId"] = "xIxP6d9N_B6Lr9nI6ddUJPv7wm5xkA9aHf1_l6R2q8Q",
          ["payload.site.siteId"] = "site-jdwt",
          ["payload.routeHint.actionHint"] = "read",
        },
      },
    },
  },
}
