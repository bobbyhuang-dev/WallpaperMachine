#include "SceneCamera.h"
#include "SceneNode.h"
#include "Utils/Logging.h"
#include <cmath>
#include <iostream>
#include <optional>
#include "Utils/Eigen.h"
#include <Eigen/LU>

using namespace wallpaper;
using namespace Eigen;

Vector3d SceneCamera::GetPosition() const {
	if(m_node) {
		m_node->UpdateTrans();
		return Affine3d(m_node->ModelTrans()) * Vector3d::Zero();
	}
	return Vector3d::Zero();
}

Vector3d SceneCamera::GetDirection() const {
	if(m_node) {
		m_node->UpdateTrans();
		return (m_node->ModelTrans() * Vector4d(0.0f, 0.0f, -1.0f, 0.0f)).head<3>();
	}
	return -Vector3d::UnitZ();
}

Vector3d SceneCamera::GetUp() const {
	if(m_node) {
		m_node->UpdateTrans();
		return (m_node->ModelTrans() * Vector4d(0.0f, 1.0f, 0.0f, 0.0f)).head<3>();
	}
	return Vector3d::UnitY();
}

Vector3d SceneCamera::GetRight() const {
	if(m_node) {
		m_node->UpdateTrans();
		return (m_node->ModelTrans() * Vector4d(1.0f, 0.0f, 0.0f, 0.0f)).head<3>();
	}
	return Vector3d::UnitX();
}

Matrix4d SceneCamera::GetViewMatrix() const {
	const_cast<SceneCamera*>(this)->Update();
	return m_viewMat;
}

Matrix4d SceneCamera::GetViewProjectionMatrix() const {
	const_cast<SceneCamera*>(this)->Update();
	return m_viewProjectionMat;
}

void SceneCamera::CalculateViewProjectionMatrix() {
	// CalculateViewMatrix
	{
		if(m_node) {
			m_node->UpdateTrans();
			m_viewMat = m_node->ModelTrans().inverse().eval();
		} else 
			m_viewMat = Matrix4d::Identity();
	};

	if(m_perspective) {
		// Skyboxes are often scaled to exactly `far`. A camera that is not on
		// the shell's center puts that surface a little past the plane, and
		// the clipper drops the whole backdrop. The pad stays small next to
		// the authored range so near-plane precision is unchanged.
		const double abs_far = m_farClip < 0.0 ? -m_farClip : m_farClip;
		const double far_pad = abs_far * 1.0e-3 > 1.0 ? abs_far * 1.0e-3 : 1.0;
		m_viewProjectionMat = Perspective(Radians(m_fov), m_aspect, m_nearClip, m_farClip + far_pad) * m_viewMat;
	} else {
		double left = -m_width/2.0f;
		double right = m_width/2.0f;
		double bottom = -m_height/2.0f;
		double up = m_height/2.0f;
		m_viewProjectionMat = Ortho(left, right, bottom, up, m_nearClip, m_farClip) * m_viewMat;
	}
}

void SceneCamera::Update() {
	CalculateViewProjectionMatrix();
}


void SceneCamera::AttatchNode(std::shared_ptr<SceneNode> node) {
	if(!node) {
		LOG_ERROR("Attach a null node to camera");		
		return;
	}
	m_node = node;
	Update();
}

SceneCamera::Axes SceneCamera::GetAxes() const {
	Axes axes;
	if (! m_node) return axes;
	m_node->UpdateTrans();
	const Eigen::Matrix4d& model = m_node->ModelTrans();
	const Eigen::Vector3d right   = model.col(0).head<3>();
	const Eigen::Vector3d up      = model.col(1).head<3>();
	const Eigen::Vector3d forward = model.col(2).head<3>();
	if (right.squaredNorm() > 1e-20) axes.right = right.normalized();
	if (up.squaredNorm() > 1e-20) axes.up = up.normalized();
	if (forward.squaredNorm() > 1e-20) axes.forward = forward.normalized();
	return axes;
}

std::optional<Eigen::Vector3d> wallpaper::IntersectNdcWithNodePlane(
	const SceneCamera& camera, SceneNode& node, double ndc_x, double ndc_y) {
	node.UpdateTrans();
	const Eigen::Matrix4d clip_from_local =
		camera.GetViewProjectionMatrix() * node.ModelTrans();
	Eigen::FullPivLU<Eigen::Matrix4d> lu(clip_from_local);
	if (! lu.isInvertible()) return std::nullopt;
	const Eigen::Matrix4d local_from_clip = lu.inverse();

	const auto unproject = [&](double clip_z) -> std::optional<Eigen::Vector3d> {
		const Eigen::Vector4d local = local_from_clip * Eigen::Vector4d(ndc_x, ndc_y, clip_z, 1.0);
		if (local.w() == 0.0 || ! std::isfinite(local.w())) return std::nullopt;
		const Eigen::Vector3d point = local.head<3>() / local.w();
		if (! point.allFinite()) return std::nullopt;
		return point;
	};

	const auto near_p = unproject(0.0);
	const auto far_p  = unproject(1.0);
	if (! near_p || ! far_p) return std::nullopt;
	const Eigen::Vector3d delta = *far_p - *near_p;
	if (! delta.allFinite()) return std::nullopt;
	constexpr double kParallel = 1e-12;
	if (std::abs(delta.z()) < kParallel) {
		if (std::abs(near_p->z()) > 1e-6) return std::nullopt;
		return *near_p;
	}
	const double t = -near_p->z() / delta.z();
	if (t < 0.0 || t > 1.0) return std::nullopt;
	const Eigen::Vector3d hit = *near_p + t * delta;
	if (! hit.allFinite()) return std::nullopt;
	return hit;
}
