import Foundation

struct BundleVerifier {
    private static let bundleMediaType = "application/vnd.dev.sigstore.bundle.v0.3+json"
    private static let payloadType = "application/vnd.in-toto+json"
    private static let statementType = "https://in-toto.io/Statement/v1"
    private static let predicateType = "https://slsa.dev/provenance/v1"
    private static let buildType = "https://actions.github.io/buildtypes/workflow/v1"
    private static let issuer = "https://token.actions.githubusercontent.com"

    let owner: String
    let repository: String
    let policy: GitHubAttestationPolicy
    let trustedRoot: SigstoreTrustedRoot

    func verify(
        _ bundle: SigstoreBundle,
        assetName: String,
        digest: Data,
        sourceCommit: String,
        repositoryID: String
    ) throws {
        guard bundle.mediaType == Self.bundleMediaType,
              bundle.dsseEnvelope.payloadType == Self.payloadType,
              bundle.dsseEnvelope.signatures.count == 1,
              bundle.verificationMaterial.tlogEntries.count == 1
        else { throw AttestationFailure.invalid("unsupported Sigstore bundle") }

        let entry = bundle.verificationMaterial.tlogEntries[0]
        let integratedSeconds = try decimal(entry.integratedTime)
        guard integratedSeconds <= 253_402_300_799 else {
            throw AttestationFailure.invalid("invalid signing time")
        }
        let integratedDate = Date(timeIntervalSince1970: TimeInterval(integratedSeconds))
        let certificate = try X509Certificate(bundle.verificationMaterial.certificate.rawBytes)
        try certificate.requireSigningUsage()
        let issuerSPKI = try trustedRoot.certificateAuthorities.lazy.compactMap { authority in
            try? certificate.verifyChain(using: authority, at: integratedDate)
        }.first.unwrap("certificate chain is not trusted")
        try certificate.verifySCT(issuerSPKI: issuerSPKI, trustedRoot: trustedRoot)

        let repoURL = "https://github.com/\(owner)/\(repository)"
        let workflowIdentity = "\(repoURL)/\(policy.workflow)@\(policy.sourceRef)"
        let statement = try JSONDecoder().decode(Statement.self, from: bundle.dsseEnvelope.payload)
        try verifyStatement(
            statement,
            assetName: assetName,
            digest: digest,
            sourceCommit: sourceCommit,
            repositoryID: repositoryID,
            repositoryURL: repoURL,
            workflowIdentity: workflowIdentity
        )

        let github = statement.predicate.buildDefinition.internalParameters.github
        let invocation = statement.predicate.runDetails.metadata.invocationId
        try certificate.requireIdentity(
            [
                "1.3.6.1.4.1.57264.1.1": Self.issuer,
                "1.3.6.1.4.1.57264.1.2": github.eventName,
                "1.3.6.1.4.1.57264.1.3": sourceCommit,
                "1.3.6.1.4.1.57264.1.5": "\(owner)/\(repository)",
                "1.3.6.1.4.1.57264.1.6": policy.sourceRef,
                "1.3.6.1.4.1.57264.1.8": Self.issuer,
                "1.3.6.1.4.1.57264.1.9": workflowIdentity,
                "1.3.6.1.4.1.57264.1.11": "github-hosted",
                "1.3.6.1.4.1.57264.1.12": repoURL,
                "1.3.6.1.4.1.57264.1.13": sourceCommit,
                "1.3.6.1.4.1.57264.1.14": policy.sourceRef,
                "1.3.6.1.4.1.57264.1.15": repositoryID,
                "1.3.6.1.4.1.57264.1.16": "https://github.com/\(owner)",
                "1.3.6.1.4.1.57264.1.17": github.repositoryOwnerID,
                "1.3.6.1.4.1.57264.1.18": workflowIdentity,
                "1.3.6.1.4.1.57264.1.19": sourceCommit,
                "1.3.6.1.4.1.57264.1.20": github.eventName,
                "1.3.6.1.4.1.57264.1.21": invocation,
                "1.3.6.1.4.1.57264.1.22": "public",
            ],
            subjectAlternativeName: workflowIdentity
        )

        let pae = dssePAE(type: bundle.dsseEnvelope.payloadType, payload: bundle.dsseEnvelope.payload)
        try certificate.verifySignature(bundle.dsseEnvelope.signatures[0].sig, message: pae)
        try verifyTransparencyEntry(
            entry,
            envelope: bundle.dsseEnvelope,
            certificate: bundle.verificationMaterial.certificate.rawBytes,
            integratedDate: integratedDate
        )
    }

    private func verifyStatement(
        _ statement: Statement,
        assetName: String,
        digest: Data,
        sourceCommit: String,
        repositoryID: String,
        repositoryURL: String,
        workflowIdentity: String
    ) throws {
        guard statement.type == Self.statementType,
              statement.predicateType == Self.predicateType,
              statement.subject.count == 1,
              statement.subject[0].name == assetName,
              statement.subject[0].digest.count == 1,
              statement.subject[0].digest["sha256"] == digest.hex
        else { throw AttestationFailure.invalid("artifact subject mismatch") }

        let definition = statement.predicate.buildDefinition
        let workflow = definition.externalParameters.workflow
        let github = definition.internalParameters.github
        let expectedGitURI = "git+\(repositoryURL)@\(policy.sourceRef)"
        let sourceMatches = definition.resolvedDependencies.filter {
            $0.uri == expectedGitURI && $0.digest.count == 1
                && $0.digest["gitCommit"]?.lowercased() == sourceCommit
        }
        guard definition.buildType == Self.buildType,
              workflow.repository == repositoryURL,
              workflow.path == policy.workflow,
              workflow.ref == policy.sourceRef,
              github.repositoryID == repositoryID,
              !github.repositoryOwnerID.isEmpty,
              github.runnerEnvironment == "github-hosted",
              sourceMatches.count == 1,
              statement.predicate.runDetails.builder.id == workflowIdentity,
              statement.predicate.runDetails.metadata.invocationId
                .hasPrefix("\(repositoryURL)/actions/runs/")
        else { throw AttestationFailure.invalid("provenance identity mismatch") }
    }

    private func verifyTransparencyEntry(
        _ entry: TransparencyEntry,
        envelope: SigstoreBundle.Envelope,
        certificate: Data,
        integratedDate: Date
    ) throws {
        guard entry.kindVersion.kind == "dsse", entry.kindVersion.version == "0.0.1" else {
            throw AttestationFailure.invalid("unsupported Rekor entry")
        }
        let logIndex = try decimal(entry.logIndex)
        let proofIndex = try decimal(entry.inclusionProof.logIndex)
        let treeSize = try decimal(entry.inclusionProof.treeSize)
        guard proofIndex < treeSize else {
            throw AttestationFailure.invalid("invalid Rekor proof index")
        }
        let logKey = try trustedRoot.logKey(id: entry.logId.keyId, at: integratedDate)

        let object = try JSONSerialization.jsonObject(with: entry.canonicalizedBody)
        guard try JSONCanonicalizer.canonicalize(object) == entry.canonicalizedBody else {
            throw AttestationFailure.invalid("non-canonical Rekor body")
        }
        let body = try JSONDecoder().decode(RekorBody.self, from: entry.canonicalizedBody)
        guard body.apiVersion == "0.0.1", body.kind == "dsse",
              body.spec.envelopeHash.algorithm == "sha256",
              body.spec.payloadHash.algorithm == "sha256",
              body.spec.signatures.count == 1,
              body.spec.payloadHash.value == envelope.payload.sha256.hex,
              Data(base64Encoded: body.spec.signatures[0].signature) == envelope.signatures[0].sig,
              try certificateFromPEMVerifier(body.spec.signatures[0].verifier) == certificate
        else { throw AttestationFailure.invalid("Rekor body mismatch") }

        let envelopeObject: [String: Any] = [
            "payload": envelope.payload.base64EncodedString(),
            "payloadType": envelope.payloadType,
            "signatures": [["sig": envelope.signatures[0].sig.base64EncodedString()]],
        ]
        guard body.spec.envelopeHash.value
            == (try JSONCanonicalizer.canonicalize(envelopeObject)).sha256.hex
        else { throw AttestationFailure.invalid("Rekor envelope hash mismatch") }

        do {
            let setPayload: [String: Any] = [
                "body": entry.canonicalizedBody.base64EncodedString(),
                "integratedTime": try decimal(entry.integratedTime),
                "logID": entry.logId.keyId.hex,
                "logIndex": logIndex,
            ]
            try verifyLogSignature(
                entry.inclusionPromise.signedEntryTimestamp,
                message: try JSONCanonicalizer.canonicalize(setPayload),
                key: logKey
            )
        } catch {
            throw AttestationFailure.invalid("invalid Rekor SET")
        }
        try Merkle.verify(
            body: entry.canonicalizedBody,
            leafIndex: proofIndex,
            treeSize: treeSize,
            hashes: entry.inclusionProof.hashes,
            expectedRoot: entry.inclusionProof.rootHash
        )
        try verifyCheckpoint(
            entry.inclusionProof.checkpoint.envelope,
            treeSize: treeSize,
            rootHash: entry.inclusionProof.rootHash,
            logID: entry.logId.keyId,
            key: logKey
        )
    }

    private func verifyCheckpoint(
        _ checkpoint: String,
        treeSize: UInt64,
        rootHash: Data,
        logID: Data,
        key: SigstoreTrustedRoot.PublicKey
    ) throws {
        let parts = checkpoint.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0].hasPrefix("rekor.sigstore.dev - "),
              parts[1] == String(treeSize),
              Data(base64Encoded: String(parts[2])) == rootHash,
              parts[3].isEmpty, parts[5].isEmpty,
              parts[4].hasPrefix("— rekor.sigstore.dev ")
        else { throw AttestationFailure.invalid("invalid Rekor checkpoint") }
        let encodedSignature = parts[4].dropFirst("— rekor.sigstore.dev ".count)
        guard let signatureWithHint = Data(base64Encoded: String(encodedSignature)),
              signatureWithHint.count > 4,
              signatureWithHint.prefix(4) == logID.prefix(4)
        else { throw AttestationFailure.invalid("invalid checkpoint signature") }
        let message = Data("\(parts[0])\n\(parts[1])\n\(parts[2])\n".utf8)
        try verifyLogSignature(Data(signatureWithHint.dropFirst(4)), message: message, key: key)
    }

    private func verifyLogSignature(
        _ signature: Data,
        message: Data,
        key: SigstoreTrustedRoot.PublicKey
    ) throws {
        switch key.keyDetails {
        case "PKIX_ECDSA_P256_SHA_256":
            try SignatureVerifier.verifyP256(
                spkiDER: key.rawBytes,
                signatureDER: signature,
                message: message
            )
        case "PKIX_ED25519":
            try SignatureVerifier.verifyEd25519(
                spkiDER: key.rawBytes,
                signature: signature,
                message: message
            )
        default:
            throw AttestationFailure.invalid("unsupported transparency log key")
        }
    }

    private func certificateFromPEMVerifier(_ encoded: String) throws -> Data {
        guard let pemData = Data(base64Encoded: encoded),
              let pem = String(data: pemData, encoding: .ascii)
        else { throw AttestationFailure.invalid("invalid Rekor verifier") }
        let base64 = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let certificate = Data(base64Encoded: base64) else {
            throw AttestationFailure.invalid("invalid Rekor certificate")
        }
        return certificate
    }

    private func decimal(_ string: String) throws -> UInt64 {
        guard !string.isEmpty, string.allSatisfy(\.isNumber),
              string == "0" || !string.hasPrefix("0"),
              let value = UInt64(string)
        else { throw AttestationFailure.invalid("invalid integer encoding") }
        return value
    }

    private func dssePAE(type: String, payload: Data) -> Data {
        var result = Data("DSSEv1 \(type.utf8.count) \(type) \(payload.count) ".utf8)
        result.append(payload)
        return result
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw AttestationFailure.invalid(message) }
        return self
    }
}
