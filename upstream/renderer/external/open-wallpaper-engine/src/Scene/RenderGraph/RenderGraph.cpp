#include <cassert>
#include <algorithm>

#include "RenderGraph.hpp"

#include "Utils/Logging.h"
#include "Pass.hpp"

using namespace wallpaper::rg;

RenderGraph::RenderGraph() {}

PassNode* RenderGraph::getPassNode(NodeID id) const {
    if(exists(m_set_passnode, id)) {
        return static_cast<PassNode*>(m_dg.GetNode(id));
    }
    return nullptr;
}

TexNode* RenderGraph::getTexNode(NodeID id) const {
    if(!exists(m_set_passnode, id)) {
        return static_cast<TexNode*>(m_dg.GetNode(id));
    }
    return nullptr;
}

Pass* RenderGraph::getPass(NodeID id) const {
    if(exists(m_map_pass, id)) {
        return m_map_pass.at(id).get();
    }
    return nullptr;
}

std::vector<NodeID> RenderGraph::topologicalOrder() const {
  std::vector<NodeID> allnodes = m_dg.TopologicalOrder();
  std::vector<NodeID> passnodes;
  std::copy_if(allnodes.begin(), allnodes.end(), std::back_inserter(passnodes), [this](auto item) {
      return exists(m_set_passnode, item) && !exists(m_set_vitrual_passnode, item);
  });
  return passnodes;
}

void RenderGraph::markPassNode(NodeID id) {
    m_set_passnode.insert(id);
}

bool RenderGraph::isPassNode(NodeID id) const {
    return exists(m_set_passnode, id);
}

RenderGraphBuilder::RenderGraphBuilder(RenderGraph& rg):m_rg(rg) {};

void  RenderGraphBuilder::setWorkPassNode(PassNode* node) {
    m_passnode_wip = node;
}

void RenderGraphBuilder::markSelfWrite(TexNode* tex) {
    if(tex->version() > 0) return;
    m_rg.addPass<VirtualPass>("virtual pass", PassNode::Type::Virtual, [tex](RenderGraphBuilder& builder, auto&) {
        builder.write(tex);
    });
}
void RenderGraphBuilder::markVirtualWrite(TexNode* tex) {
    if(tex->version() > 0 || tex->writer() != nullptr) return;
    m_rg.addPass<VirtualPass>("virtual pass", PassNode::Type::Virtual, [tex](RenderGraphBuilder& builder, auto&) {
        builder.write(tex);
    });
}

TexNode* RenderGraphBuilder::createTexNode(const TexNode::Desc& desc, bool write) {
    TexNode* node {nullptr};
    if(exists(m_rg.m_key_texnode, desc.key)) {
        auto* old = m_rg.getTexNode(m_rg.m_key_texnode.at(desc.key));
        if( write && old->writer() != nullptr) {
            node = createNewTexNode(desc);
        } else {
            node = old;
        }
    } else {
        node = createNewTexNode(desc);
    }
    assert(node != nullptr);
    return node;
}

TexNode* RenderGraphBuilder::createNewTexNode(const TexNode::Desc& desc) {
    TexNode* node {nullptr};
    if(exists(m_rg.m_key_texnode, desc.key)) {
        auto* old = m_rg.getTexNode(m_rg.m_key_texnode.at(desc.key));
        node = TexNode::addNewVersion(m_rg.m_dg, old);
    } else {
        node = TexNode::addTexNode(m_rg.m_dg, desc);
    }
    m_rg.m_key_texnode[desc.key] = node->ID();
    return node;
}

void RenderGraphBuilder::read(TexNode* texnode) {
    m_rg.m_dg.Connect(texnode->ID(), m_passnode_wip->ID());

    // reader before all new version's writer
    auto* next = texnode->nextVer();
    if(next != nullptr && next->m_writer != nullptr) {
        m_rg.m_dg.Connect(m_passnode_wip->ID(), next->m_writer->ID());
    }
}

void RenderGraphBuilder::write(TexNode* node) {
    // after all old reader
    if(node->version() > 0) {
        auto* old = node->preVer();
        const auto& outs = m_rg.m_dg.GetNodeOut(old->ID());
        // after reader
        for(auto id:outs) {
            if(m_rg.isPassNode(id)) {
                m_rg.m_dg.Connect(id, m_passnode_wip->ID());
            }
        }
        // after old tex if no old reader
        if(outs.empty())
            m_rg.m_dg.Connect(old->ID(), m_passnode_wip->ID());
    }
    m_rg.m_dg.Connect(m_passnode_wip->ID(), node->ID());
    node->setWriter(m_passnode_wip);
}


const PassNode& RenderGraphBuilder::workPassNode() const {
    return *m_passnode_wip;
}

std::vector<std::vector<TexNode*>> RenderGraph::getLastReadTexs(std::span<const NodeID> nodes) const {
    std::vector<std::vector<TexNode*>> res(nodes.size());
    // Logical versions of a render target all map to the same TextureCache
    // key/allocation. Releasing a version at its last reader lets a later
    // target overwrite it while subsequent versions still need its contents
    // (including blend-only writes). Track the last access of the entire key.
    Set<std::string> seen_keys;
    for (std::size_t i = nodes.size(); i-- > 0;) {
        const auto collect = [&](const auto& edges) {
            for (const auto id : edges) {
                auto* tex = getTexNode(id);
                if (tex != nullptr && seen_keys.insert(std::string(tex->key())).second) {
                    res[i].push_back(tex);
                }
            }
        };
        collect(m_dg.GetNodeIn(nodes[i]));
        collect(m_dg.GetNodeOut(nodes[i]));
    }
    return res;
}
