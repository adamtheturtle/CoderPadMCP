//
//  Schema.swift
//  CoderPadMCP
//
//  Builds the standalone server's `MCP.Tool` list from the single shared catalog in
//  CoderPadToolCore (#521), so the CLI advertises exactly the same tools - names,
//  descriptions, schemas, gating, annotations - as the in-app server. The generic
//  descriptor->`Tool` conversion now lives in MCPKit (`mcpTools`); this keeps only the
//  CoderPad-specific selection of which descriptors to advertise.
//

import CoderPadToolCore
import MCP
import MCPKit

/// The tools to advertise, built from the shared catalog: Screen tools appear only when
/// Screen is configured, write tools only when writes are opted in.
public func availableTools(screenEnabled: Bool, writesEnabled: Bool) -> [Tool] {
    mcpTools(from: coderPadToolDescriptors(screenEnabled: screenEnabled, writesEnabled: writesEnabled))
}
