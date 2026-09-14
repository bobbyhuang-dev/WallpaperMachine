#include "SceneCamera.h"
#include "SceneNode.h"
#include "Utils/Logging.h"
#include <iostream>
#include "Utils/Eigen.h"

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
		m_viewProjectionMat = Perspective(Radians(m_fov), m_aspect, m_nearClip, m_farClip) * m_viewMat;
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
